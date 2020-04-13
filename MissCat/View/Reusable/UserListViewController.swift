//
//  UserListViewController.swift
//  MissCat
//
//  Created by Yuiga Wada on 2020/04/13.
//  Copyright © 2020 Yuiga Wada. All rights reserved.
//

import RxCocoa
import RxDataSources
import RxSwift
import UIKit

typealias UsersDataSource = RxTableViewSectionedAnimatedDataSource<UserCell.Section>
class UserListViewController: NoteDisplay, UITableViewDelegate {
    @IBOutlet weak var mainTableView: MissCatTableView!
    
    private var viewModel: UserListViewModel?
    private lazy var dataSource = self.setupDataSource()
    private let disposeBag: DisposeBag = .init()
    
    private var withTopShadow: Bool = false
    private var topShadow: CALayer?
    
    // MARK: I/O
    
    func setup(type: UserListType, userId: String? = nil, query: String? = nil, listId: String? = nil, withTopShadow: Bool = false) {
        let input = UserListViewModel.Input(dataSource: dataSource,
                                            type: type,
                                            userId: userId,
                                            query: query,
                                            listId: listId)
        
        let viewModel: UserListViewModel = .init(with: input, and: disposeBag)
        self.viewModel = viewModel
        self.withTopShadow = withTopShadow
    }
    
    // MARK: LifeCycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupTopShadow()
        
        if viewModel == nil {
            setup(type: .search)
        }
        
        binding(dataSource: dataSource)
        viewModel?.setupInitialCell()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.deselectCell(on: mainTableView)
        
        viewModel?.setSkeltonCell()
    }
    
    private func binding(dataSource: UsersDataSource?) {
        guard let viewModel = viewModel, let dataSource = dataSource else { return }
        
        let output = viewModel.output
        output.users.bind(to: mainTableView.rx.items(dataSource: dataSource)).disposed(by: disposeBag)
    }
    
    // MARK: Setup
    
    private func setupTableView() {
        mainTableView.register(UINib(nibName: "UserCell", bundle: nil), forCellReuseIdentifier: "UserCell")
        mainTableView.delegate = self
    }
    
    private func setupDataSource() -> UsersDataSource {
        let dataSource = UsersDataSource(
            animationConfiguration: AnimationConfiguration(insertAnimation: .fade, reloadAnimation: .none, deleteAnimation: .fade),
            configureCell: { dataSource, _, indexPath, _ in
                self.setupCell(dataSource, self.mainTableView, indexPath)
            }
        )
        
        return dataSource
    }
    
    private func setupTopShadow() {
        guard withTopShadow,
            let target = mainTableView else { return }
        
        let path = UIBezierPath(rect: CGRect(x: -5.0, y: -5.0, width: target.bounds.size.width + 5.0, height: 3.0))
        let innerLayer = CALayer()
        innerLayer.frame = target.bounds
        innerLayer.masksToBounds = true
        innerLayer.shadowColor = UIColor.black.cgColor
        innerLayer.shadowOffset = CGSize(width: 2.5, height: 2.5)
        innerLayer.shadowOpacity = 0.5
        innerLayer.isHidden = true
        innerLayer.shadowPath = path.cgPath
        view.layer.addSublayer(innerLayer)
        
        topShadow = innerLayer
    }
    
    private func setupCell(_ dataSource: TableViewSectionedDataSource<UserCell.Section>, _ tableView: UITableView, _ indexPath: IndexPath) -> UITableViewCell {
        guard let viewModel = viewModel else { fatalError("Internal Error.") }
        
        let index = indexPath.row
        let item = viewModel.cellsModel[index]
        
        guard let itemCell = tableView.dequeueReusableCell(withIdentifier: "UserCell", for: indexPath) as? UserCell else { fatalError("Internal Error.") }
        
        if item.isSkelton {
            return itemCell.transform(isSkelton: true)
        }
        
        let shapedCell = itemCell.transform(with: .init(icon: item.icon,
                                                        shapedName: item.shapedName,
                                                        shapedDescription: item.shapedDescritpion))
        
        shapedCell.nameTextView.renderViewStrings()
        shapedCell.descriptionTextView.renderViewStrings()
        
        return shapedCell
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        topShadow?.isHidden = scrollView.contentOffset.y <= 0
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let viewModel = viewModel else { return }
        
        let index = indexPath.row
        
        // 下位4分の1のcellでセル更新
        let state = viewModel.state
        guard !state.isLoading, viewModel.cellsModel.count - indexPath.row < 40 / 4 else { return } //  state.cellCompleted,
        
        print("loadUntilUsers...")
        viewModel.loadUntilUsers().subscribe(onError: { error in
            if let error = error as? TimelineModel.NotesLoadingError, error == .NotesEmpty { return }
            self.homeViewController?.showNotificationBanner(icon: .Failed, notification: error.description)
        }).disposed(by: disposeBag)
    }
}
