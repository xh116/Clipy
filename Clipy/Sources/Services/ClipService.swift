//
//  ClipService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/11/17.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import Cocoa
import RealmSwift
import PINCache
import RxSwift
import RxCocoa
import RxOptional

final class ClipService {

    // MARK: - Properties
    fileprivate var cachedChangeCount = BehaviorRelay<Int>(value: 0)
    fileprivate var storeTypes = [String: NSNumber]()
    fileprivate let scheduler = SerialDispatchQueueScheduler(qos: .userInteractive)
    fileprivate let lock = NSRecursiveLock(name: "com.clipy-app.Clipy.ClipUpdatable")
    fileprivate var disposeBag = DisposeBag()

    // MARK: - Clips
    func startMonitoring() {
        disposeBag = DisposeBag()
        // Pasteboard observe timer
        Observable<Int>.interval(.milliseconds(750), scheduler: scheduler)
            .map { _ in NSPasteboard.general.changeCount }
            .withLatestFrom(cachedChangeCount.asObservable()) { ($0, $1) }
            .filter { $0 != $1 }
            .subscribe(onNext: { [weak self] changeCount, _ in
                self?.cachedChangeCount.accept(changeCount)
                self?.create()
            })
            .disposed(by: disposeBag)
        // Store types
        AppEnvironment.current.defaults.rx
            .observe([String: NSNumber].self, Constants.UserDefaults.storeTypes)
            .filterNil()
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] in
                self?.storeTypes = $0
            })
            .disposed(by: disposeBag)
    }

    func clearAll() {
        let realm = try! Realm()
        let clips = realm.objects(CPYClip.self)
            .filter(CPYClip.predicateNotPinned)

        // Delete saved images
        clips
            .filter { !$0.thumbnailPath.isEmpty }
            .map { $0.thumbnailPath }
            .forEach { PINCache.shared.removeObject(forKey: $0) }
        // Delete Realm
        realm.transaction { realm.delete(clips) }
        // Delete writed datas
        AppEnvironment.current.dataCleanService.cleanDatas()
    }

    func delete(with clip: CPYClip) {
        let realm = try! Realm()
        // Delete saved images
        let path = clip.thumbnailPath
        if !path.isEmpty {
            PINCache.shared.removeObject(forKey: path)
        }
        // Delete Realm
        realm.transaction { realm.delete(clip) }
    }

    func incrementChangeCount() {
        cachedChangeCount.accept(cachedChangeCount.value + 1)
    }

    func pin(with clip: CPYClip) {
        lock.lock()
        defer {
            lock.unlock()
        }
        let realm = try! Realm()
        let pinIndex = clip.isPinned ? 0 : getNextPinIndex()
        realm.transaction {
            clip.pinIndex = pinIndex
            realm.add(clip, update: .modified)
        }
    }

    func getAllHistoryClip() -> [CPYClip] {
        let sortByUpdateTime = AppEnvironment.current.reorderClipsAfterPasting
        let hidePinnedHistory = AppEnvironment.current.hidePinnedHistory
        let maxHistory = AppEnvironment.current.maxHistorySize
        let filter = hidePinnedHistory ? CPYClip.predicateNotPinned : CPYClip.predicateAny
        let sortKeyPath = sortByUpdateTime ? #keyPath(CPYClip.updateTime) : #keyPath(CPYClip.createTime)
        let realm = try! Realm()
        let clips = realm.objects(CPYClip.self).filter(filter).sorted(byKeyPath: sortKeyPath, ascending: false).prefix(maxHistory)
        if !sortByUpdateTime {
            return clips.reversed()
        }
        return Array(clips)
    }

    func getAllPinnedClip() -> Results<CPYClip> {
        let realm = try! Realm()
        return realm.objects(CPYClip.self)
            .filter(CPYClip.predicatePinned)
            .sorted(byKeyPath: #keyPath(CPYClip.pinIndex), ascending: true)
    }

    func getNextPinIndex() -> Int {
        return Int(NSDate().timeIntervalSince1970 * 1000)
    }

    func clip(forPrimaryKey primaryKey: String) -> CPYClip? {
        let realm = try! Realm()
        return realm.object(ofType: CPYClip.self, forPrimaryKey: primaryKey)
    }

    func overflowingClips() -> Results<CPYClip> {
        let sortByUpdateTime = AppEnvironment.current.reorderClipsAfterPasting
        let hidePinnedHistory = AppEnvironment.current.hidePinnedHistory
        let maxHistory = AppEnvironment.current.maxHistorySize
        let filter = hidePinnedHistory ? CPYClip.predicateNotPinned : CPYClip.predicateAny
        let sortKeyPath = sortByUpdateTime ? #keyPath(CPYClip.updateTime) : #keyPath(CPYClip.createTime)
        let realm = try! Realm()
        guard let lastClip = realm.objects(CPYClip.self).filter(filter).sorted(byKeyPath: sortKeyPath, ascending: false)
            .prefix(maxHistory).last, !lastClip.isInvalidated else {
                return realm.objects(CPYClip.self).filter("FALSEPREDICATE")
        }
        let time = sortByUpdateTime ? lastClip.updateTime : lastClip.createTime
        return realm.objects(CPYClip.self).filter(sortKeyPath + " < %d", time)
    }
}

// MARK: - Create Clip
extension ClipService {
    fileprivate func create() {
        lock.lock(); defer { lock.unlock() }

        // Store types
        if !storeTypes.values.contains(NSNumber(value: true)) { return }
        // Pasteboard types
        let pasteboard = NSPasteboard.general
        let types = self.types(with: pasteboard)
        if types.isEmpty { return }

        // Excluded application
        guard !AppEnvironment.current.excludeAppService.frontProcessIsExcludedApplication() else { return }
        // Special applications
        guard !AppEnvironment.current.excludeAppService.copiedProcessIsExcludedApplications(pasteboard: pasteboard) else { return }

        // Create data
        let data = CPYClipData(pasteboard: pasteboard, types: types)
        save(with: data)
    }

    func create(with image: NSImage) {
        lock.lock(); defer { lock.unlock() }

        // Create only image data
        let data = CPYClipData(image: image)
        save(with: data)
    }

    fileprivate func save(with data: CPYClipData) {
        let realm = try! Realm()
        // Copy already copied history
        let isCopySameHistory = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.copySameHistory)
        let oldClip = realm.object(ofType: CPYClip.self, forPrimaryKey: "\(data.hash)")
        if oldClip != nil, !isCopySameHistory { return }
        // Don't save invalidated clip
        if let clip = oldClip, clip.isInvalidated {
            return
        }
        // Don't save empty string history
        if data.isOnlyStringType && data.stringValue.isEmpty { return }

        // Overwrite same history
        let isOverwriteHistory = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.overwriteSameHistory)
        let savedHash = (isOverwriteHistory) ? data.hash : Int(arc4random() % 1000000)

        // Saved time and path
        let unixTime = Int(Date().timeIntervalSince1970)
        if let clip = oldClip, isOverwriteHistory {
            realm.transaction {
                clip.updateTime = unixTime
                realm.add(clip, update: .modified)
            }
            return
        }

        let savedPath = CPYUtilities.applicationSupportFolder() + "/\(NSUUID().uuidString).data"

        // Create Realm object
        DispatchQueue.main.sync {
            var thumbnailPath: String?
            var isColorCode = false
            // Save thumbnail image
            if let thumbnailImage = data.thumbnailImage {
                PINCache.shared.setObject(thumbnailImage, forKey: "\(unixTime)")
                thumbnailPath = "\(unixTime)"
            } else if let colorCodeImage = data.colorCodeImage {
                PINCache.shared.setObject(colorCodeImage, forKey: "\(unixTime)")
                thumbnailPath = "\(unixTime)"
                isColorCode = true
            }
            // Save Realm and .data file
            let dispatchRealm = try! Realm()
            if CPYUtilities.prepareSaveToPath(CPYUtilities.applicationSupportFolder()) {
                if NSKeyedArchiver.archiveRootObject(data, toFile: savedPath) {
                    dispatchRealm.transaction {
                        let clip = CPYClip()
                        clip.dataPath = savedPath
                        clip.title = data.stringValue[0...10000]
                        clip.dataHash = "\(savedHash)"
                        clip.updateTime = unixTime
                        clip.createTime = unixTime
                        clip.primaryType = data.primaryType?.rawValue ?? ""
                        clip.thumbnailPath = thumbnailPath ?? ""
                        clip.isColorCode = isColorCode
                        if clip.title.isEmpty, let filename = data.fileNames.first(where: { $0.isNotEmpty }) {
                            clip.title = filename
                        }
                        if clip.title.isEmpty, let url = data.URLs.first(where: { $0.isNotEmpty }) {
                            clip.title = url
                        }
                        dispatchRealm.add(clip, update: .modified)
                    }
                }
            }
        }
    }

    private func types(with pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let types = pasteboard.types?.filter { canSave(with: $0) } ?? []
        return NSOrderedSet(array: types).array as? [NSPasteboard.PasteboardType] ?? []
    }

    private func canSave(with type: NSPasteboard.PasteboardType) -> Bool {
        guard let availableType = AvailableType.available(by: type) else { return false }
        guard let number = storeTypes[availableType.rawValue] else { return false }
        return number.boolValue
    }
}
