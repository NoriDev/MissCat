//
//  NoteCellViewModel.swift
//  MissCat
//
//  Created by Yuiga Wada on 2019/11/19.
//  Copyright © 2019 Yuiga Wada. All rights reserved.
//

import MisskeyKit
import RxCocoa
import RxSwift
import UIKit

class NoteCellViewModel: ViewModelType {
    // MARK: I/O
    
    struct Input {
        let cellModel: NoteCell.Model
        let isDetailMode: Bool
        
        // Modelに渡さなければならないので看過
        let noteYanagi: MisskeyTextView
        let nameYanagi: MisskeyTextView
    }
    
    struct Output {
        let ago: PublishRelay<String> = .init()
        let name: PublishRelay<NSAttributedString?> = .init()
        
        let shapedNote: PublishRelay<NSAttributedString?> = .init()
        let url: PublishRelay<String> = .init()
        
        let reactions: PublishSubject<[NoteCell.Reaction.Section]> = .init()
        let poll: PublishRelay<Poll> = .init()
        let commentRenoteTarget: PublishRelay<NoteCell.Model> = .init()
        let onOtherNote: PublishRelay<Bool> = .init() // 引用RNはNoteCellの上にNoteCellが乗るという二重構造になっているので、内部のNoteCellかどうかを判別する
        
        let iconImage: PublishRelay<UIImage> = .init()
        let innerIconImage: PublishRelay<UIImage> = .init()
        
        let defaultConstraintActive: PublishRelay<Bool> = .init()
        let isReplyTarget: PublishRelay<Bool> = .init()
        
        let backgroundColor: PublishRelay<UIColor> = .init()
        
        let displayName: String
        let username: String
    }
    
    struct State {
        var previewedUrl: String?
    }
    
    private var input: Input
    lazy var output: Output = .init(displayName: input.cellModel.displayName,
                                    username: input.cellModel.username)
    var state: State {
        return .init(previewedUrl: previewedUrl)
    }
    
    private var previewedUrl: String?
    
    private let replyTargetColor = UIColor(hex: "f0f0f0")
    private let usernameFont = UIFont.systemFont(ofSize: 11.0)
    
    private var dataSource: ReactionsDataSource?
    var reactionsModel: [NoteCell.Reaction] = []
    private var model = NoteCellModel()
    private var disposeBag: DisposeBag
    
    private var properBackgroundColor: UIColor {
        return input.cellModel.isReplyTarget ? replyTargetColor : .white
    }
    
    // MARK: Life Cycle
    
    init(with input: Input, and disposeBag: DisposeBag) {
        self.input = input
        self.disposeBag = disposeBag
    }
    
    func setCell() {
        let item = input.cellModel
        DispatchQueue.global(qos: .default).async {
            self.output.isReplyTarget.accept(item.isReplyTarget)
            self.output.backgroundColor.accept(self.properBackgroundColor)
            self.output.ago.accept(item.ago.calculateAgo())
        }
        
        output.name.accept(input.cellModel.shapedDisplayName?.attributed)
        output.shapedNote.accept(input.cellModel.shapedNote?.attributed)
        output.defaultConstraintActive.accept(!input.isDetailMode)
        
        input.cellModel.shapedDisplayName?.mfmEngine.renderCustomEmojis(on: input.nameYanagi)
        input.cellModel.shapedNote?.mfmEngine.renderCustomEmojis(on: input.noteYanagi)
        
        getReactions(item)
        prepareCommentRenote(item)
        output.onOtherNote.accept(item.onOtherNote)
        
        setImage(to: output.iconImage, username: item.username, imageRawUrl: item.iconImageUrl)
        setImage(to: output.innerIconImage, username: item.commentRNTarget?.username, imageRawUrl: item.commentRNTarget?.iconImageUrl)
        
        getUrl(from: item)
        if let pollModel = item.poll {
            output.poll.accept(pollModel)
        }
    }
    
    func setReactionCell(with item: NoteCell.Reaction, to reactionCell: ReactionCell) -> ReactionCell {
        guard let rawEmoji = item.rawEmoji else { return reactionCell }
        
        if let customEmojiUrl = item.url {
            reactionCell.setup(noteId: item.noteId,
                               count: item.count,
                               customEmoji: customEmojiUrl,
                               isMyReaction: item.isMyReaction,
                               rawReaction: rawEmoji)
        } else {
            reactionCell.setup(noteId: item.noteId,
                               count: item.count,
                               rawDefaultEmoji: rawEmoji,
                               isMyReaction: item.isMyReaction,
                               rawReaction: rawEmoji)
        }
        
        return reactionCell
    }
    
    func setImage(to target: PublishRelay<UIImage>, username: String?, imageRawUrl: String?) {
        guard let username = username, let imageRawUrl = imageRawUrl else { return }
        
        if let image = Cache.shared.getIcon(username: username) {
            target.accept(image)
        } else if let imageUrl = URL(string: imageRawUrl) {
            imageUrl.toUIImage { image in
                guard let image = image else { return }
                Cache.shared.saveIcon(username: username, image: image) // CACHE!
                target.accept(image)
            }
        }
    }
    
    /// ファイルの種類を識別する
    /// - Parameter type: MIME Type
    func checkFileType(_ type: String?) -> FileType {
        guard let type = type else { return .Unknown }
        
        if type.contains("video") {
            return .Video
        } else if type.contains("audio") {
            return .Audio
        }
        
        let isImage: Bool = type.contains("image")
        let isGif: Bool = type.contains("gif")
        
        return isImage ? (isGif ? .GIFImage : .PlaneImage) : .Unknown
    }
    
    private func getReactions(_ item: NoteCell.Model) {
        reactionsModel = []
        
        reactionsModel = item.shapedReactions
        updateReactions(new: item.shapedReactions)
    }
    
    private func hasAttachments(on yanagi: YanagiText, with attachments: [NSTextAttachment: YanagiText.Attachment]?) -> Bool {
        guard let attachments = attachments else { return true }
        
        let yanagiAttachments = yanagi.getAttachments()
        var attachmentCount = 0
        
        attachments.forEach { key, value in
            if let value_ = yanagiAttachments[key], value_.view === value.view {
                attachmentCount += 1
            }
        }
        
        return attachmentCount == attachments.count // 一致しない＝キャッシュされたattachmentsに欠損あり
    }
    
    private func getUrl(from item: NoteCell.Model) {
        guard let url = searchUrl(from: item) else { return }
        
        previewedUrl = url
        output.url.accept(url)
    }
    
    private func searchUrl(from item: NoteCell.Model) -> String? {
        let normalLink = "(https?://[\\w/:%#\\$&\\?\\(~\\.=\\+\\-@\"]+)"
        let targets = item.original?.text?.regexMatches(pattern: normalLink).map { $0[0] }
        if let targets = targets, targets.count > 0 {
            return targets[0]
        }
        return nil
    }
    
    private func prepareCommentRenote(_ item: NoteCell.Model) {
        guard let renoteCellModel = item.commentRNTarget else { return }
        output.commentRenoteTarget.accept(renoteCellModel)
    }
    
    func registerReaction(noteId: String, reaction: String) {
        model.registerReaction(noteId: noteId, reaction: reaction)
    }
    
    func cancelReaction(noteId: String) {
        model.cancelReaction(noteId: noteId)
    }
    
    private func updateReactions(new: [NoteCell.Reaction]) {
        updateReactions(new: [NoteCell.Reaction.Section(items: new)])
    }
    
    private func updateReactions(new: [NoteCell.Reaction.Section]) {
        output.reactions.onNext(new)
    }
}
