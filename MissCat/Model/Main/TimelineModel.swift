//
//  HomeModel.swift
//  MissCat
//
//  Created by Yuiga Wada on 2019/11/13.
//  Copyright © 2019 Yuiga Wada. All rights reserved.
//

import MisskeyKit
import RxCocoa
import RxSwift

// MARK: ENUM

enum TimelineType {
    case Home
    case Local
    case Social
    case Global
    
    case UserList
    case OneUser
    
    case NoteSearch
    
    var needsStreaming: Bool {
        return self != .UserList && self != .OneUser
    }
    
    func convert2Channel() -> SentStreamModel.Channel? { // TimelineTypeをMisskeyKit.SentStreamModel.Channelに変換する
        switch self {
        case .Home: return .homeTimeline
        case .Local: return .localTimeline
        case .Social: return .hybridTimeline
        case .Global: return .globalTimeline
        default: return nil
        }
    }
}

// MARK: CLASS

class TimelineModel {
    // MARK: I/O
    
    struct LoadOption {
        let type: TimelineType
        let userId: String?
        let untilId: String?
        let includeReplies: Bool?
        let onlyFiles: Bool?
        let listId: String?
        let loadLimit: Int
        let query: String?
        
        let isReload: Bool
        let lastNoteId: String?
    }
    
    struct UpdateReaction {
        let targetNoteId: String?
        let rawReaction: String?
        let isMyReaction: Bool
        let plus: Bool
        let externalEmoji: EmojiModel?
    }
    
    struct Trigger {
        let removeTargetTrigger: PublishSubject<String> // arg: noteId
        let updateReactionTrigger: PublishSubject<UpdateReaction>
    }
    
    enum NotesLoadingError: Error {
        case NotesEmpty
    }
    
    lazy var trigger: Trigger = .init(removeTargetTrigger: self.removeTargetTrigger,
                                      updateReactionTrigger: self.updateReactionTrigger)
    
    let removeTargetTrigger: PublishSubject<String> = .init() // arg: noteId
    let updateReactionTrigger: PublishSubject<UpdateReaction> = .init()
    
    var initialNoteIds: [String] = []
    private var capturedNoteIds: [String] = []
    
    private var type: TimelineType = .Home
    private let handleTargetType: [String] = ["note", "CapturedNoteUpdated"]
    private lazy var streaming = misskey?.streaming
    
    private let misskey: MisskeyKit?
    private let owner: SecureUser
    init(from misskey: MisskeyKit?, owner: SecureUser) {
        self.misskey = misskey
        self.owner = owner
    }
    
    // MARK: REST API
    
    /// 投稿を読み込む
    /// - Parameter option: LoadOption
    func loadNotes(with option: LoadOption, from owner: SecureUser) -> Observable<NoteCell.Model> {
        let dispose = Disposables.create()
        
        return Observable.create { [unowned self] observer in
            
            let handleResult = self.getNotesHandler(with: option, and: observer, owner: owner)
            switch option.type {
            case .Home:
                self.misskey?.notes.getTimeline(limit: option.loadLimit,
                                                untilId: option.untilId ?? "",
                                                completion: handleResult)
                
            case .Local:
                self.misskey?.notes.getLocalTimeline(limit: option.loadLimit,
                                                     untilId: option.untilId ?? "",
                                                     completion: handleResult)
                
            case .Social:
                self.misskey?.notes.getHybridTimeline(limit: option.loadLimit,
                                                      untilId: option.untilId ?? "",
                                                      completion: handleResult)
            case .Global:
                self.misskey?.notes.getGlobalTimeline(limit: option.loadLimit,
                                                      untilId: option.untilId ?? "",
                                                      completion: handleResult)
                
            case .OneUser:
                guard let userId = option.userId else { return dispose }
                self.misskey?.notes.getUserNotes(includeReplies: option.includeReplies ?? true,
                                                 userId: userId,
                                                 withFiles: option.onlyFiles ?? false,
                                                 limit: option.loadLimit,
                                                 untilId: option.untilId ?? "",
                                                 completion: handleResult)
                
            case .UserList:
                guard let listId = option.listId else { return dispose }
                self.misskey?.notes.getUserListTimeline(listId: listId,
                                                        limit: option.loadLimit,
                                                        untilId: option.untilId ?? "",
                                                        completion: handleResult)
            case .NoteSearch:
                guard let query = option.query else { return dispose }
                self.misskey?.search.notes(query: query,
                                           limit: option.loadLimit,
                                           untilId: option.untilId ?? "",
                                           result: handleResult)
            }
            
            return dispose
        }
    }
    
    func report(message: String, userId: String) {
        misskey?.users.reportAsAbuse(userId: userId, comment: message) { _, _ in
        }
    }
    
    func block(_ userId: String) {
        misskey?.users.block(userId: userId) { _, _ in
        }
    }
    
    func deleteMyNote(_ noteId: String) {
        misskey?.notes.deletePost(noteId: noteId) { _, _ in
        }
    }
    
    // MARK: Handler (REST API)
    
    /// handleNotes()をパラメータを補ってNotesCallBackとして返す
    /// - Parameters:
    ///   - option: LoadOption
    ///   - observer: AnyObserver<NoteCell.Model>
    private func getNotesHandler(with option: LoadOption, and observer: AnyObserver<NoteCell.Model>, owner: SecureUser) -> NotesCallBack {
        return { (posts: [NoteModel]?, error: MisskeyKitError?) in
            self.handleNotes(option: option, observer: observer, posts: posts, owner: owner, error: error)
        }
    }
    
    /// MisskeyKitから流れてきた投稿データを適切にobserverへと流していく
    private func handleNotes(option: LoadOption, observer: AnyObserver<NoteCell.Model>, posts: [NoteModel]?, owner: SecureUser, error: MisskeyKitError?) {
        let isInitalLoad = option.untilId == nil
        let isReload = option.isReload && (option.lastNoteId != nil)
        
        guard let posts = posts, error == nil else {
            if let error = error { observer.onError(error) }
            print(error ?? "error is nil")
            return
        }
        
        if posts.count == 0 { // 新規登録された場合はpostsが空集合
            observer.onError(NotesLoadingError.NotesEmpty)
        }
        
        if isReload {
            // timelineにすでに表示してある投稿を取得した場合、ロードを終了する
            var newPosts: [NoteModel] = []
            for index in 0 ..< posts.count {
                let post = posts[index]
                if !post.isRecommended { // ハイライトの投稿は無視する
                    // 表示済みの投稿に当たったらbreak
                    guard option.lastNoteId != post.id, option.lastNoteId != post.renoteId else { break }
                    newPosts.append(post)
                }
            }
            
            newPosts.reverse() // 逆順に読み込む
            newPosts.forEach { post in
                self.transformNote(with: observer, post: post, owner: owner, reverse: true)
                if let noteId = post.id { self.initialNoteIds.append(noteId) }
            }
            
            observer.onCompleted()
            return
        }
        
        // if !isReload...
        
        posts.forEach { post in
            // 初期ロード: prのみ表示する / 二回目からはprとハイライトを無視
            let ignore = isInitalLoad ? post.isFeatured : post.isRecommended
            guard !ignore else { return }
            
            self.transformNote(with: observer, post: post, owner: owner, reverse: false)
            if let noteId = post.id {
                self.initialNoteIds.append(noteId) // ここでcaptureしようとしてもwebsocketとの接続が未確定なのでcapture不確実
            }
        }
        
        observer.onCompleted()
    }
    
    /// self.misskey?.NoteModelをNoteCell.Modelへ変換してobserverへ送る
    /// - Parameters:
    ///   - observer: AnyObserver<NoteCell.Model>
    ///   - post: NoteModel
    ///   - reverse: 逆順に送るかどうか
    private func transformNote(with observer: AnyObserver<NoteCell.Model>, post: NoteModel, owner: SecureUser, reverse: Bool) {
        let noteType = checkNoteType(post)
        if noteType == .Renote { // renoteの場合 ヘッダーとなるrenoteecellとnotecell、２つのモデルを送る
            guard let renoteId = post.renoteId,
                  let user = post.user,
                  let renote = post.renote,
                  let renoteModel = renote.getNoteCellModel(owner: owner, withRN: checkNoteType(renote) == .CommentRenote) else { return }
            
            let renoteeModel = NoteCell.Model.fakeRenoteecell(renotee: user.name ?? user.username ?? "",
                                                              renoteeUserName: user.username ?? "",
                                                              baseNoteId: renoteId)
            
            var cellModels = [renoteeModel, renoteModel]
            if reverse { cellModels.reverse() }
            
            for cellModel in cellModels {
                MFMEngine.shapeModel(cellModel)
                observer.onNext(cellModel)
            }
        } else if noteType == .Promotion { // PR投稿
            guard let noteId = post.id,
                  let cellModel = post.getNoteCellModel(owner: owner, withRN: checkNoteType(post) == .CommentRenote) else { return }
            
            let prModel = NoteCell.Model.fakePromotioncell(baseNoteId: noteId)
            var cellModels = [prModel, cellModel]
            
            if reverse { cellModels.reverse() }
            
            for cellModel in cellModels {
                MFMEngine.shapeModel(cellModel)
                observer.onNext(cellModel)
            }
        } else { // just a note or a note with commentRN
            var newCellsModel = getCellsModel(post, withRN: noteType == .CommentRenote)
            guard newCellsModel != nil else { return }
            
            if reverse { newCellsModel!.reverse() } // reverseしてからinsert (streamingの場合)
            newCellsModel!.forEach {
                MFMEngine.shapeModel($0)
                observer.onNext($0)
            }
        }
    }
    
    // MARK: Streaming API
    
    /// Streamingへと接続する
    /// - Parameters:
    ///   - type: TimelineType
    ///   - reconnect: 再接続かどうか
    func connectStream(owner: SecureUser, type: TimelineType, isReconnection reconnect: Bool = false) -> Observable<NoteCell.Model> { // streamingのresponseを捌くのはhandleStreamで行う
        let dipose = Disposables.create()
        var isReconnection = reconnect
        self.type = type
        
        return Observable.create { [unowned self] observer in
            guard let apiKey = self.misskey?.auth.getAPIKey(), let channel = type.convert2Channel() else { return dipose }
            
            _ = self.streaming?.connect(apiKey: apiKey, channels: [channel]) { (response: Any?, channel: SentStreamModel.Channel?, type: String?, error: MisskeyKitError?) in
                self.captureNote(&isReconnection)
                self.handleStream(owner: owner,
                                  response: response,
                                  channel: channel,
                                  typeString: type,
                                  error: error,
                                  observer: observer)
            }
            
            return dipose
        }
    }
    
    /// Streamingで流れてきたデータを適切にobserverへと流す
    private func handleStream(owner: SecureUser, response: Any?, channel: SentStreamModel.Channel?, typeString: String?, error: MisskeyKitError?, observer: AnyObserver<NoteCell.Model>) {
        if let error = error {
            print(error)
            if error == .CannotConnectStream || error == .NoStreamConnection { // streaming関連のエラーのみ流す
                observer.onError(error)
            }
            return
        }
        
        guard let _ = channel,
              let typeString = typeString,
              self.handleTargetType.contains(typeString) else { return }
        
        // captureした投稿に対して更新が行われた場合
        if typeString == "CapturedNoteUpdated" {
            guard let updateContents = response as? NoteUpdatedModel, let updateType = updateContents.type else { return }
            
            switch updateType {
            case .reacted:
                guard let userId = updateContents.userId else { return }
                userId.isMe(owner: owner) { isMyReaction in // 自分のリアクションかどうかチェックする
                    guard !isMyReaction else { return } // 自分のリアクションはcaptureしない
                    self.updateReaction(targetNoteId: updateContents.targetNoteId,
                                        reaction: updateContents.reaction,
                                        isMyReaction: isMyReaction,
                                        plus: true,
                                        external: updateContents.emoji)
                }
                
            case .pollVoted:
                break
                
            case .unreacted:
                guard let userId = updateContents.userId else { return }
                userId.isMe(owner: owner) { isMyReaction in
                    guard !isMyReaction else { return } // 自分のリアクションはcaptureしない
                    self.updateReaction(targetNoteId: updateContents.targetNoteId,
                                        reaction: updateContents.reaction,
                                        isMyReaction: false,
                                        plus: false)
                }
                
            case .deleted:
                guard let targetNoteId = updateContents.targetNoteId else { return }
                removeTargetTrigger.onNext(targetNoteId)
            }
        }
        
        // 通常の投稿
        if let post = response as? NoteModel {
            DispatchQueue.main.async {
                self.transformNote(with: observer, post: post, owner: owner, reverse: true)
            }
            captureNote(noteId: post.id)
        }
    }
    
    // MARK: Capture
    
    private func captureNote(_ isReconnection: inout Bool) {
        // 再接続の場合
        if isReconnection {
            captureNotes(capturedNoteIds, isReconnection)
            isReconnection = false
        }
        
        let isInitialConnection = initialNoteIds.count > 0 // 初期接続かどうか
        if isInitialConnection {
            captureNotes(initialNoteIds)
            initialNoteIds = []
        }
    }
    
    private func captureNote(noteId: String?) {
        guard let noteId = noteId else { return }
        captureNotes([noteId])
    }
    
    private func captureNotes(_ noteIds: [String], _ isReconnection: Bool = false) {
        noteIds.forEach { id in
            do {
                try streaming?.captureNote(noteId: id)
            } catch {
                /* Ignore :P */
            }
        }
        
        if !isReconnection { // streamingが切れた時のために記憶
            capturedNoteIds += noteIds.filter { !capturedNoteIds.contains($0) } // 重複しないように
        }
    }
    
    // MARK: Update Cell
    
    private func updateReaction(targetNoteId: String?, reaction rawReaction: String?, isMyReaction: Bool, plus: Bool, external externalEmoji: EmojiModel? = nil) {
        let updateReaction = UpdateReaction(targetNoteId: targetNoteId,
                                            rawReaction: rawReaction,
                                            isMyReaction: isMyReaction,
                                            plus: plus,
                                            externalEmoji: externalEmoji)
        
        updateReactionTrigger.onNext(updateReaction)
    }
    
    // MisskeyKitのNoteModelをNoteCell.Modelに変換する
    func getCellsModel(_ post: NoteModel, withRN: Bool = false) -> [NoteCell.Model]? {
        var cellsModel: [NoteCell.Model] = []
        
        if let reply = post.reply { // リプライ対象も表示する
            let replyWithRN = checkNoteType(reply) == .CommentRenote
            let replyCellModel = reply.getNoteCellModel(owner: owner, withRN: replyWithRN)
            
            if replyCellModel != nil {
                replyCellModel!.isReplyTarget = true
                cellsModel.append(replyCellModel!)
            }
        }
        
        if let cellModel = post.getNoteCellModel(owner: owner, withRN: withRN) {
            cellsModel.append(cellModel)
        }
        
        return cellsModel.count > 0 ? cellsModel : nil
    }
    
    func vote(choice: Int, to noteId: String) {
        misskey?.notes.vote(noteId: noteId, choice: choice, result: { _, _ in
            //            print(error)
        })
    }
    
    func renote(noteId: String) {
        misskey?.notes.renote(renoteId: noteId) { _, _ in
            //            print(error)
        }
    }
}

// MARK; Utilities
extension TimelineModel {
    fileprivate enum NoteType {
        case Renote
        case CommentRenote
        case Note
        case Promotion
    }
    
    /// NoteModelが RNなのか、引用RNなのか、ただの投稿なのか判別する
    /// - Parameter post: NoteModel
    private func checkNoteType(_ post: NoteModel) -> NoteType {
        guard post._prId_ == nil else { return .Promotion }
        
        let isRenote = post.renoteId != nil && post.user != nil && post.renote != nil
        let isCommentRenote = isRenote && post.text != nil && post.text != ""
        return isRenote ? (isCommentRenote ? .CommentRenote : .Renote) : .Note
    }
}
