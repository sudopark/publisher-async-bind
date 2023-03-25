//
//  File.swift
//  
//
//  Created by sudo.park on 2023/03/15.
//

import Foundation


struct RuntimeError: Error {
    let message: String
    init(_ message: String = "failed") {
        self.message = message
    }
}
