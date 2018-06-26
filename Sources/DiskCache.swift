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

open class DiskCache<ValueType: DataConvertable> {
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
    private let allowedFilesystemCharacters: CharacterSet = {
        var chars = CharacterSet(charactersIn: UnicodeScalar(0) ... UnicodeScalar(31)) // 0x00-0x1F
        chars.insert(UnicodeScalar(127)) // 0x7F
        chars.insert(charactersIn: "\"*/:<>?\\|")
        return chars.inverted
    }()

    /**
     Max byte length of (encoded) filenames. Files with longer names keep the maximum suffix length
     with a UUID string prefix.
     */
    private let maxFilenameLength = 255

    /**
     Length (bytes) of an UUID string.
     */
    private let uuidLength = 36

    /**
     Name of extended attribute that stores expire date.
     */
    private let expireDateAttributeName = "no.nrk.yr.cachyr.expireDate"

    /**
     Name of the extended attribute that holds the key.
     */
    private let keyAttributeName = "no.nrk.yr.cachyr.key"

    /**
     Map of keys to storage keys. Since keys can have length longer than the filename length limit,
     they must be mapped to a shorter unique key used as the filename. The actual key is stored in an
     extended attribute on the file, thus creating a simple file-based database.
     */
    private var storageKeyMap = [String: String]()

    /**
     Storage for the url property.
     */
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

    /**
     The minimum amount of time elapsed before a new check for expired items is run.
     */
    public var checkExpiredInterval: TimeInterval = 10 * 60

    /**
     Returns true if enough time has lapsed to start a check for expired items.
     */
    public var shouldCheckExpired: Bool {
        return (Date().timeIntervalSince1970 - lastRemoveExpired.timeIntervalSince1970) > checkExpiredInterval
    }

    /**
     Last time expired items were removed.
     */
    public private(set) var lastRemoveExpired = Date(timeIntervalSince1970: 0)

    public init(name: String = "no.nrk.yr.cache.disk", baseURL: URL? = nil) {
        self.name = name

        if let baseURL = baseURL {
            self.url = baseURL.appendingPathComponent(name, isDirectory: true)
        } else {
            if let cachesURL = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                self.url = cachesURL.appendingPathComponent(name, isDirectory: true)
            } else {
                CacheLog.error("Unable to get system cache directory URL")
            }
        }

        loadStorageKeyMap()
    }

    public func contains(key: String) -> Bool {
        guard let url = mappedFileURL(for: key) else {
            return false
        }
        return accessQueue.sync {
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    public func value(forKey key: String) -> ValueType? {
        return accessQueue.sync {
            removeExpiredAfterInterval()

            guard let data = fileFor(key: key) else {
                return nil
            }

            if let value = ValueType.value(from: data) {
                return value
            } else {
                CacheLog.warning("Could not convert data to \(ValueType.self)")
                return nil
            }
        }
    }

    public func setValue(_ value: ValueType, forKey key: String, expires: Date? = nil) {
        accessQueue.sync {
            removeExpiredAfterInterval()

            guard let data = ValueType.data(from: value) else {
                CacheLog.warning("Could not convert \(value) to Data")
                return
            }
            addFile(for: key, data: data, expires: expires)
        }
    }

    public func removeValue(forKey key: String) {
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

    public func expirationDate(forKey key: String) -> Date? {
        guard let url = mappedFileURL(for: key) else {
            return nil
        }
        return accessQueue.sync {
            return expirationForFile(url)
        }
    }

    public func setExpirationDate(_ date: Date?, forKey key: String) {
        guard let url = mappedFileURL(for: key) else {
            return
        }
        accessQueue.sync {
            setExpiration(date, for: url)
        }
    }

    public func removeItems(olderThan date: Date) {
        accessQueue.sync {
            let allFiles = filesInCache(properties: [.nameKey, .creationDateKey])
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
        return self.url?.appendingPathComponent(key)
    }

    private func mappedFileURL(for key: String) -> URL? {
        guard let storageKey = storageKeyMap[key] else {
            return nil
        }
        return fileURL(for: storageKey)
    }

    private func fileFor(key: String) -> Data? {
        guard let fileURL = mappedFileURL(for: key) else {
            return nil
        }

        if fileExpired(fileURL: fileURL) {
            removeFile(for: key)
            return nil
        }

        return FileManager.default.contents(atPath: fileURL.path)
    }

    private func filesInCache(properties: [URLResourceKey]? = [.nameKey]) -> [URL] {
        guard let url = self.url else {
            return []
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: properties, options: [.skipsHiddenFiles])
            return files
        } catch {
            CacheLog.error("\(error)")
            return []
        }
    }

    func storageName(for key: String) -> String {
        let encodedKey = encode(key: key)
        guard encodedKey.lengthOfBytes(using: .utf8) > maxFilenameLength else {
            return encodedKey
        }

        var length = maxFilenameLength
        var suffix: Substring = ""
        repeat {
            // Dropping characters doesn't necessarily give us the wanted byte length
            suffix = encodedKey.suffix(length)
            length -= 4
        } while suffix.lengthOfBytes(using: .utf8) > maxFilenameLength

        let prefix = UUID().uuidString
        var truncatedKey = String(suffix)
        let beginIndex = truncatedKey.startIndex
        let endIndex = truncatedKey.index(beginIndex, offsetBy: uuidLength)
        truncatedKey.replaceSubrange(beginIndex ..< endIndex, with: prefix)

        return truncatedKey
    }

    private func addFile(for key: String, data: Data, expires: Date? = nil) {
        let fileURL: URL

        let storageKey = storageKeyMap[key] ?? storageName(for: key)
        if let url = self.fileURL(for: storageKey) {
            fileURL = url
        } else {
            CacheLog.error("Unable to create file URL for \(storageKey)")
            return
        }

        let fm = FileManager.default
        if !fm.createFile(atPath: fileURL.path, contents: data, attributes: nil) {
            CacheLog.error("Unable to create file at \(fileURL.path)")
            return
        }

        guard let keyData = key.data(using: .utf8) else {
            CacheLog.error("Key is not UTF-8 compatible: \(key)")
            storageKeyMap[key] = nil
            try? fm.removeItem(at: fileURL)
            return
        }

        do {
            try fm.setExtendedAttribute(keyAttributeName, on: fileURL, data: keyData)
        } catch {
            CacheLog.error("\(error)")
            storageKeyMap[key] = nil
            try? fm.removeItem(at: fileURL)
            return
        }

        storageKeyMap[key] = storageKey

        if let expires = expires {
            setExpiration(expires, for: fileURL)
        }
    }

    private func removeFile(for key: String) {
        guard let fileURL = self.mappedFileURL(for: key) else {
            CacheLog.error("Unable to create file URL for '\(key)'")
            return
        }
        storageKeyMap[key] = nil
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

    // MARK: Expiration

    /**
     Check expiration date extended attribute of file.
     */
    private func expirationForFile(_ url: URL) -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try FileManager.default.extendedAttribute(expireDateAttributeName, on: url)
            guard let epoch = Double.value(from: data) else {
                CacheLog.error("Unable to convert extended attribute data to expire date.")
                return nil
            }
            let date = Date(timeIntervalSince1970: epoch)
            return date
        } catch let error as ExtendedAttributeError {
            // Missing expiration attribute is not an error
            if error.code != ENOATTR {
                CacheLog.error("\(error.name) \(error.code) \(error.description)")
            }
        } catch {
            CacheLog.error("Error getting expire date extended attribute on \(url.path)")
        }

        return nil
    }

    /**
     Set expiration date of file as extended attribute. Set it to nil to remove it.
     */
    private func setExpiration(_ expiration: Date?, for file: URL) {
        guard let expires = expiration else {
            do {
                try FileManager.default.removeExtendedAttribute(expireDateAttributeName, from: file)
            } catch let error as ExtendedAttributeError {
                CacheLog.error("\(error.name) \(error.code) \(error.description) \(file.path)")
            } catch {
                CacheLog.error("Error removing expire date extended attribute on \(file.path)")
            }
            return
        }

        do {
            let epoch = expires.timeIntervalSince1970
            guard let data = Double.data(from: epoch) else {
                CacheLog.error("Unable to convert expiry date \(expires) to data")
                return
            }
            try FileManager.default.setExtendedAttribute(expireDateAttributeName, on: file, data: data)
        } catch let error as ExtendedAttributeError {
            CacheLog.error("\(error.name) \(error.code) \(error.description) \(file.path)")
        } catch {
            CacheLog.error("Error setting expire date extended attribute on \(file.path)")
        }
    }

    private func removeExpiredItems() {
        let allFiles = filesInCache()
        let files = allFiles.filter { fileExpired(fileURL: $0) }
        for fileURL in files {
            if let key = keyForFile(fileURL) {
                storageKeyMap[key] = nil
            }
            removeFile(at: fileURL)
        }

        lastRemoveExpired = Date()
    }

    private func removeExpiredAfterInterval() {
        if !shouldCheckExpired {
            return
        }
        removeExpiredItems()
    }

    private func fileExpired(fileURL: URL) -> Bool {
        guard let date = expirationForFile(fileURL) else {
            return false
        }
        return date < Date()
    }

    // MARK: Storage key

    /**
     Get key from extended attribute of file.
     */
    private func keyForFile(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return nil
        }

        var key: String?
        do {
            let data = try fm.extendedAttribute(keyAttributeName, on: url)
            key = String(data: data, encoding: .utf8)
        } catch {
            CacheLog.error("\(error)")
        }

        return key
    }

    /**
     Set key as extended attribute.
     */
    private func setKey(_ key: String, for file: URL) -> Bool {
        guard let data = key.data(using: .utf8) else {
            CacheLog.error("Unable to convert key \(key) to data")
            return false
        }

        var didSet = false
        do {
            try FileManager.default.setExtendedAttribute(keyAttributeName, on: file, data: data)
            didSet = true
        } catch let error as ExtendedAttributeError {
            CacheLog.error("\(error.name) \(error.code) \(error.description) \(file.path)")
        } catch {
            CacheLog.error("Error setting expire date extended attribute on \(file.path)")
        }

        return didSet
    }

    /**
     Reset storage key map and load all keys from files in cache.
     */
    private func loadStorageKeyMap() {
        storageKeyMap.removeAll()

        let files = filesInCache()
        for file in files {
            let key: String
            let storageKey: String

            if let foundKey = keyForFile(file) {
                key = foundKey
                storageKey = file.lastPathComponent
            } else {
                // Old key scheme where filename is the key
                key = decode(key: file.lastPathComponent)
                storageKey = storageName(for: key)
                guard setKey(key, for: file) else {
                    continue
                }
            }

            storageKeyMap[key] = storageKey
        }
    }
}
