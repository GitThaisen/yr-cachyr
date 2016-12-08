/**
 *  Cachyr
 *
 *  Copyright (c) 2016 NRK. Licensed under the MIT license, as follows:
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 */

import Foundation

open class DiskCache {
    /**
     Name of cache.
     Names should be unique enough to separate different caches.
     Reverse domain notation, like no.nrk.yr.cache, is a good choice.
     */
    public let name: String

    /**
     Queue used to synchronize disk cache access. The cache allows concurrent reads
     but only serial writes using barriers.
     */
    private let accessQueue = DispatchQueue(label: "no.nrk.yr.cache.disk.queue")

    /**
     Character set with all allowed file system characters. The ones not allowed are based on
     NTFS/exFAT limitations, which is a superset of HFS+ and most UNIX file system limitations.

     [Comparison of filename limitations](https://en.wikipedia.org/wiki/Filename#Comparison_of_filename_limitations)
     */
    private let allowedFilesystemCharacters: CharacterSet

    /**
     The HFS+ file system currently uses 32-bit timestamps, which means max expiry date is 2038-01-19T03:14:07 UTC.
     The disk cache max expiry is set to 2038-01-01T00:00:00 UTC.
     */
    private let maxExpireDateForFilesystem = Date(timeIntervalSince1970: 2145916800)

    private var _url: URL?
    /**
     URL of cache directory, of the form: `baseURL/name`
     */
    public private(set) var url: URL? {
        get {
            guard let url = _url else { return nil }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            } catch {
                CacheLog.error("Unable to create \(url.path)")
                return nil
            }
            return url
        }
        set {
            _url = newValue
        }
    }

    public var checkExpiredInterval: TimeInterval = 10 * 60

    public var isCheckExpiredIntervalDone: Bool {
        return (Date().timeIntervalSince1970 - lastRemoveExpired.timeIntervalSince1970) > checkExpiredInterval
    }

    public private(set) var lastRemoveExpired = Date(timeIntervalSince1970: 0)
    
    public init(name: String = "no.nrk.yr.cache.disk", baseURL: URL? = nil) {
        self.name = name

        var chars = CharacterSet(charactersIn: UnicodeScalar(0) ... UnicodeScalar(31)) // 0x00-0x1F
        chars.insert(UnicodeScalar(127)) // 0x7F
        chars.insert(charactersIn: "\"*/:<>?\\|")
        allowedFilesystemCharacters = chars.inverted

        if let baseURL = baseURL {
            self.url = baseURL.appendingPathComponent(name, isDirectory: true)
        } else {
            if let cachesURL = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                self.url = cachesURL.appendingPathComponent(name, isDirectory: true)
            } else {
                CacheLog.error("Unable to get system cache directory URL")
            }
        }
    }

    public func value<ValueType: DataConvertable>(for key: String) -> ValueType? {
        var value: ValueType? = nil
        accessQueue.sync {
            removeExpiredAfterInterval()

            guard let data = fileFor(key: key) else {
                return
            }

            value = ValueType.value(from: data)
            if value == nil {
                CacheLog.warning("Could not convert data to \(ValueType.self)")
            }
        }

        return value
    }

    public func setValue<ValueType: DataConvertable>(_ value: ValueType, for key: String, expires: Date? = nil) {
        accessQueue.sync {
            removeExpiredAfterInterval()

            guard let data = ValueType.data(from: value) else {
                CacheLog.warning("Could not convert \(value) to Data")
                return
            }
            addFile(for: key, data: data, expires: expires)
        }
    }

    public func removeValue(for key: String) {
        accessQueue.sync {
            removeFile(for: key)
        }
    }

    public func removeAll() {
        accessQueue.sync {
            guard let cacheURL = self.url else {
                return
            }
            do {
                try FileManager.default.removeItem(at: cacheURL)
            }
            catch let error {
                CacheLog.error(error.localizedDescription)
            }
        }
    }

    public func removeExpired() {
        accessQueue.sync {
            removeExpiredItems()
        }
    }

    public func removeItems(olderThan date: Date) {
        accessQueue.sync {
            guard let url = url else { return }
            let allFiles: [URL]
            do {
                allFiles = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.creationDateKey])
            }
            catch let error {
                CacheLog.error(error.localizedDescription)
                return
            }

            allFiles.forEach { (fileUrl) in
                guard let resourceValues = try? fileUrl.resourceValues(forKeys: [.creationDateKey]) else { return }
                if let created = resourceValues.creationDate, created <= date {
                    removeFile(at: fileUrl)
                }
            }
        }
    }

    func encode(key: String) -> String {
        return key.addingPercentEncoding(withAllowedCharacters: allowedFilesystemCharacters)!
    }

    func decode(key: String) -> String {
        return key.removingPercentEncoding!
    }

    private func fileURL(for key: String) -> URL? {
        let encodedKey = encode(key: key)
        return self.url?.appendingPathComponent(encodedKey)
    }

    private func fileFor(key: String) -> Data? {
        guard let fileURL = fileURL(for: key) else {
            return nil
        }

        if fileExpired(fileURL: fileURL) {
            removeFile(for: key)
            return nil
        }

        return FileManager.default.contents(atPath: fileURL.path)
    }

    private func addFile(for key: String, data: Data, expires: Date? = nil) {
        guard let fileURL = fileURL(for: key) else {
            CacheLog.error("Unable to create file URL for \(key)")
            return
        }
        var attribs = [String: Any]()
        let expireDate = (expires != nil && expires! < maxExpireDateForFilesystem) ? expires! : maxExpireDateForFilesystem
        attribs[FileAttributeKey.modificationDate.rawValue] = expireDate
        if !FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: attribs) {
            CacheLog.error("Unable to create file at \(fileURL.path)")
        }
    }

    private func removeFile(for key: String) {
        guard let fileURL = fileURL(for: key) else {
            CacheLog.error("Unable to create file URL for '\(key)'")
            return
        }
        removeFile(at: fileURL)
    }

    private func removeFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        }
        catch let error {
            CacheLog.error(error.localizedDescription)
        }
    }

    private func removeExpiredItems() {
        guard let url = url else { return }
        let allFiles: [URL]
        do {
            allFiles = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        catch let error {
            CacheLog.error(error.localizedDescription)
            return
        }

        let files = allFiles.filter { fileExpired(fileURL: $0) }
        for fileURL in files {
            removeFile(at: fileURL)
        }
    }

    private func removeExpiredAfterInterval() {
        if !isCheckExpiredIntervalDone {
            return
        }
        removeExpiredItems()
    }

    /**
     Check expiration date of file.
     Since cache files are never modified (only overwritten), modification time is used as expiration date.
     */
    private func fileExpired(fileURL: URL) -> Bool {
        let attribs: [FileAttributeKey: Any]
        do {
            attribs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        }
        catch {
            return false
        }
        guard let expireDate = attribs[.modificationDate] as? Date else {
            return false
        }
        if expireDate < Date() {
            return true
        }
        return false
    }
}
