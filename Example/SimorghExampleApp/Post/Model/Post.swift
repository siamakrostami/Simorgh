//
//  Post.swift
//  SimorghExampleApp
//
//  Created by Siamak Rostami on 9/20/24.
//


// MARK: - Post.swift

import Foundation

struct Post: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let body: String
}
