// String+Regex.swift
// YouTube Lite
//
// Created by Antigravity on 2026-05-18.
//

import Foundation

extension String {
    func firstMatch(pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(self.startIndex..., in: self)),
              match.numberOfRanges > group else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
