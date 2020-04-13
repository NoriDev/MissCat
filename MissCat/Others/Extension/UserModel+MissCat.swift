//
//  UserModel+MissCat.swift
//  MissCat
//
//  Created by Yuiga Wada on 2020/04/13.
//  Copyright © 2020 Yuiga Wada. All rights reserved.
//

import MisskeyKit

extension UserModel {
    func getUserCellModel() -> UserCell.Model {
        return UserCell.Model(userId: id,
                              icon: avatarUrl,
                              name: name,
                              username: username,
                              description: description)
    }
}
