//
//  DataCleanService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/11/20.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import RxSwift
import RealmSwift
import PINCache

final class DataCleanService {

    // MARK: - Properties
    fileprivate var disposeBag = DisposeBag()
    fileprivate let scheduler = SerialDispatchQueueScheduler(qos: .utility)

    // MARK: - Monitoring
    func startMonitoring() {
        disposeBag = DisposeBag()
        // Clean datas every 30 minutes
        Observable<Int>.interval(.seconds(60 * 30), scheduler: scheduler)
            .subscribe(onNext: { [weak self] _ in
                self?.cleanDatas()
            })
            .disposed(by: disposeBag)
    }

    // MARK: - Delete Data
    func cleanDatas() {
        let realm = try! Realm()
        let flowHistories = overflowingClips()
        flowHistories
            .filter { !$0.isInvalidated && !$0.thumbnailPath.isEmpty }
            .map { $0.thumbnailPath }
            .forEach { PINCache.shared.removeObject(forKey: $0) }
        realm.transaction { realm.delete(flowHistories) }
        cleanFiles(with: realm)
    }

    private func overflowingClips() -> Results<CPYClip> {
        return AppEnvironment.current.clipService.overflowingClips()
    }

    private func cleanFiles(with realm: Realm) {
        let fileManager = FileManager.default
        guard let paths = try? fileManager.contentsOfDirectory(atPath: CPYUtilities.applicationSupportFolder()) else { return }

        let allClipPaths = Array(realm.objects(CPYClip.self)
            .filter { !$0.isInvalidated }
            .compactMap { $0.dataPath.components(separatedBy: "/").last })

        // Delete diff datas
        DispatchQueue.main.async {
            Set(allClipPaths).symmetricDifference(paths)
                .map { CPYUtilities.applicationSupportFolder() + "/" + "\($0)" }
                .forEach { CPYUtilities.deleteData(at: $0) }
        }
    }
}
