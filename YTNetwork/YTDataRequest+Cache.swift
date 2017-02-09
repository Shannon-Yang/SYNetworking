//
//  YTDataRequest+Cache.swift
//  YTNetwork
//
//  Created by Shannon Yang on 2016/11/28.
//  Copyright © 2016年 Hangzhou Yunti Technology Co. Ltd. All rights reserved.
//

import Foundation
import Alamofire

/// cache load error type

enum LoadCacheError: Error {
    
    /// does not match the cache key
    
    case cacheKeyMismatch
    
    /// cache Time Expired
    
    case expiredCacheTime
    
    /// cache Time invalid
    
    case invalidCacheTime
    
    /// cached data is invalid
    
    case invalidCacheData
    
    /// Invalid metadata cache
    
    case invalidMetadata
    
    /// invalid request
    
    case invalidRequest
}

/// can do a cache plugin for YTDataRequest

extension YTDataRequest {
    
    /// Update the local cache of the current request, If the cache exists, it overwrites the existing cache,You can go to update existing cache by this method,
    ///
    /// This method will only cacheTimeInSeconds set to greater than 0 to store success,otherwise fails
    ///
    /// - Parameter data: Need to cache data,If optionalData is nil, do not store operation
    
    func cacheToFile(_ responseData: Data?) {

        guard self.cacheTimeInSeconds > 0 else {
            return
        }
        guard let data = responseData else {
            return
        }
        guard !self.requestUrl.isEmpty else {
            return
        }
        let path = self.cacheFilePath()
        let cacheQueue = DispatchQueue(label: "com.ytnetwork.cache", attributes: .concurrent)
        cacheQueue.async {
            do {
                // New data will always overwrite old data.
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                let metadata = self.configCacheMetadata()
                NSKeyedArchiver.archiveRootObject(metadata, toFile: self.cacheMetadataFilePath().path)
            } catch let error {
                print("write to file failed = \(error)")
            }
        }
    }
    
    
    /// load local cache
    ///
    /// - Returns: cache data
    /// - Throws: cache load error type
    
    func loadLocalCache() throws -> Data? {
        
        if self.requestUrl.isEmpty {
            throw LoadCacheError.invalidRequest
        }
        
        // Make sure cache time in valid.
        
        if self.cacheTimeInSeconds == 0 {
            throw LoadCacheError.invalidCacheTime
        }
        
        // Try load metadata.
        
        if !self.loadCacheMetadata() {
            throw LoadCacheError.invalidMetadata
        }
        
        // Check if cache is still valid.
        
        do {
            _ = try self.validateCacheWithError()
        } catch let error {
            throw error
        }
        
        // Try load cache.
        
        guard let data = self.loadCacheData() else {
            throw LoadCacheError.invalidCacheData
        }
        
         return data
    }
    
   
    /// Clear local cache for the current request
    
    func clearLocalCache() throws {
        let path = self.cacheFilePath()
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error {
            print("clear local cache failed, error = \(error)")
            throw error
        }
    }
    
    
    /// Clear all request's local cache
    
    static func clearAllLocalCache() throws {
        let pathOfLibrary = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0]
        let path = "\(pathOfLibrary)/\(Key.YTNetworkCache.rawValue)"
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error {
            print("clear all local cache failed, error = \(error)")
            throw error
        }
    }
}


//MARK: - Private YTRequest

private extension YTDataRequest {
    
    enum Key: String {
        case YTNetworkCache
        case requestMethod
        case baseUrl
        case requestUrl
        case requestParameters
        case cacheKey
    }
    
    func configCacheMetadata() -> YTCacheMetadata {
        let metadata = YTCacheMetadata()
        metadata.cacheKey = self.cacheKey
        metadata.creationDate = Date()
        metadata.responseStringEncoding = self.stringEncodingWithRequest(request: self)
        metadata.responseJSONOptions = self.responseJSONOptions
        metadata.responsePropertyListOptions = self.responsePropertyListOptions
        metadata.responseObjectKeyPath = self.responseObjectKeyPath
        metadata.responseObjectContext = self.responseObjectContext
        return metadata
    }
    
    func cacheFilePath() -> String {
        let fileName = self.cacheFileName()
        let pathURL = self.cacheBasePath()
        let path = pathURL.appendingPathComponent(fileName).path
        return path
    }
    
    
    func cacheBasePath() -> URL {
        let pathOfLibrary = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let pathURL = pathOfLibrary.appendingPathComponent(Key.YTNetworkCache.rawValue)
        self.createDirectoryIfNeeded(path: pathURL.path)
        return pathURL
    }
    
    
    func createBaseDirectoryAtPath(path: String) {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            self.addDoNotBackupAttribute(path: path)
        } catch let error {
            print("create cache directory failed, error = \(error)")
        }
    }
    
    func cacheFileName() -> String {
        let requestMethod = self.requestMethod
        let baseUrl = YTNetworkConfig.sharedInstance.baseUrlString
        let requestUrl = self.requestUrl
        let requestParameters = self.requestParameters
        let cacheKey = self.cacheKey
        let requestInfo = "\(Key.requestMethod.rawValue):\(requestMethod) \(Key.baseUrl.rawValue):\(baseUrl) \(Key.requestUrl.rawValue):\(requestUrl) \(Key.requestParameters.rawValue):\(requestParameters) \(Key.cacheKey.rawValue):\(cacheKey)"
        return requestInfo.md5()
    }
    
    func createDirectoryIfNeeded(path: String) {
        var isDir : ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue {
                // file exists and is not a directory
                do {
                    try FileManager.default.removeItem(atPath: path)
                    self.createBaseDirectoryAtPath(path: path)
                } catch let error {
                    print("file remove failed, error = \(error)")
                }
            }
        } else {
            // file does not exist
            self.createBaseDirectoryAtPath(path: path)
        }
    }
    
    func addDoNotBackupAttribute(path: String) {
        let url = NSURL(fileURLWithPath: path)
        do {
            // https://bugs.swift.org/browse/SR-3289
            try url.setResourceValue(NSNumber.init(value: true), forKey: URLResourceKey.isExcludedFromBackupKey)
        } catch let error {
            print("error to set do not backup attribute, error = \(error)")
        }
    }
    
    func cacheMetadataFilePath() -> URL {
        let cacheMetadataFileName = "\(self.cacheFileName()).metadata"
        let pathURL = self.cacheBasePath().appendingPathComponent(cacheMetadataFileName)
        return pathURL
    }
    
    func loadCacheData() -> Data? {
        let path = self.cacheFilePath()
        let url = URL(fileURLWithPath: path)
        return try? Data(contentsOf: url)
    }

    func loadCacheMetadata() -> Bool {
        let pathURL = self.cacheMetadataFilePath()
        if FileManager.default.fileExists(atPath: pathURL.path, isDirectory: nil) {
            if let cacheMetadata = NSKeyedUnarchiver.unarchiveObject(withFile: pathURL.path) as? YTCacheMetadata {
                self.cacheMetadata = cacheMetadata
                return true
            }
        }
        return false
    }
    
    func validateCacheWithError() throws -> Bool {
        
        guard let cacheMetadata = self.cacheMetadata else {
            throw LoadCacheError.invalidMetadata
        }
        
        // Date
        
        let creationDate = cacheMetadata.creationDate
        let duration = -Int(creationDate.timeIntervalSinceNow)
        if duration < 0 || duration > self.cacheTimeInSeconds {
            throw LoadCacheError.expiredCacheTime
        }
        
        // cacheKey
        
        if cacheMetadata.cacheKey != self.cacheKey {
            throw LoadCacheError.cacheKeyMismatch
        }
        
        return true
    }
    
    
    func stringEncodingWithRequest(request: YTRequest) -> String.Encoding {
        var convertedEncoding = String.Encoding.isoLatin1
        if let encodingName = request.response?.textEncodingName as CFString! {
            convertedEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(encodingName))
            )
        }
        return convertedEncoding
    }
}