//
//  PostsAPI.swift
//  SimorghExampleApp
//
//  Created by Siamak Rostami on 9/20/24.
//

// MARK: - PostsAPI.swift

import Foundation
import Simorgh

struct PostsAPI: NetworkRouter, Sendable {
    var baseURLString: String { "https://jsonplaceholder.typicode.com/" }
    var method: RequestMethod? { .get }
    var path: String { "posts" }
    var headers: [String: String]? { nil }
    var params: Parameters? { nil }
    var queryParams: QueryParameters? { nil }
}
