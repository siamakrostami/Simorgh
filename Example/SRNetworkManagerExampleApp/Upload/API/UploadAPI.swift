//
//  UploadAPI.swift
//  SRNetworkManagerExampleApp
//
//  Created by Siamak on 12/18/24.
//

import Foundation
import Simorgh

struct UploadAPI: Sendable, NetworkRouter {
    var baseURLString: String { "https://file.io/" }
    var method: RequestMethod? { .post }
    var headers: [String: String]? {
        HeaderHandler.shared.addAcceptHeaders(type: .applicationJson)
            .addContentTypeHeader(type: .formData)
            .build()
    }
}
