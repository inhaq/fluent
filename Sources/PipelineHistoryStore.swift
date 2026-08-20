import Foundation
import CoreData
import os

/// Raised when an operation is attempted against a store that never loaded.
///
/// Previously these paths returned an empty success, so a failed write looked
/// identical to a successful one and the in-memory history silently diverged
/// from disk.
struct PipelineHistoryStoreUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Run history storage is unavailable."
    }
}

/// Outcome of a successful ``PipelineHistoryStore/append(_:maxCount:completion:)``.
///
/// Committing the row and trimming to the limit are two transactions that fail
/// differently. The row is durable either way, so a trim failure rides along
/// with the success instead of replacing it: reporting it as an append failure
/// would have the caller delete the audio file the committed row references.
struct PipelineHistoryAppendResult {
    /// Audio filenames of the entries the trim dropped. Safe to delete on disk.
    let droppedAudioFileNames: [String]

    /// Set when the row committed but the trim did not. History is over its
    /// limit, and the audio files of the rows that should have been dropped are
    /// still on disk, until something retries — the next append, or the trim and
    /// orphan sweep at launch.
    let trimError: Error?
}

final class PipelineHistoryStore {
    private let container: NSPersistentContainer
    private let storeState = OSAllocatedUnfairLock(initialState: StoreState.loading)

    /// Serial queue every store operation runs on.
    ///
    /// Starts suspended and is resumed once the persistent store finishes
    /// loading, so callers can enqueue work immediately at launch without
    /// anything blocking on the store being ready. Serial ordering matters:
    /// an `append` must be visible to the `trim` that follows it.
    private let workQueue: OperationQueue

    /// Long-lived private-queue context for all mutations. `viewContext` is the
    /// main-queue context and is reserved for reads that must be main-thread
    /// coherent — writing through it put SQLite inserts (up to 500 KB of base64
    /// screenshot) on the main thread after every dictation.
    private lazy var writeContext: NSManagedObjectContext = {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }()

    private enum StoreState {
        case loading
        case loaded
        case failed
    }

    private enum LoadAttempt {
        case initial
        case recovered
    }

    init() {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "PipelineHistory", managedObjectModel: model)

        workQueue = OperationQueue()
        workQueue.name = "com.inhaq.fluent.history.store"
        workQueue.maxConcurrentOperationCount = 1
        workQueue.qualityOfService = .utility
        workQueue.isSuspended = true

        var storeURL: URL?
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appName = AppName.displayName
            let baseURL = appSupport.appendingPathComponent(appName, isDirectory: true)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            storeURL = baseURL.appendingPathComponent("PipelineHistory.sqlite")
        }

        container.persistentStoreDescriptions = [Self.makeDescription(url: storeURL)]
        loadStores(storeURL: storeURL, attempt: .initial)
    }

    // MARK: - Store loading

    /// Builds a store description that loads **off** the calling thread.
    ///
    /// `shouldAddStoreAsynchronously` defaults to `false`, which makes
    /// `loadPersistentStores` open SQLite, replay the WAL, and evaluate
    /// lightweight migration synchronously on whichever thread called it — the
    /// main thread, during `AppState.init()`. Setting it moves all of that to a
    /// private queue.
    private static func makeDescription(url: URL?) -> NSPersistentStoreDescription {
        let description = url.map(NSPersistentStoreDescription.init(url:)) ?? NSPersistentStoreDescription()
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = true
        return description
    }

    private func loadStores(storeURL: URL?, attempt: LoadAttempt) {
        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            guard let error else {
                self.finishLoading(.loaded)
                return
            }

            switch attempt {
            case .initial:
                guard let storeURL else {
                    print("[PipelineHistoryStore] No store URL available: \(error). History is disabled.")
                    self.finishLoading(.failed)
                    return
                }
                print("[PipelineHistoryStore] Failed to load persistent store at \(storeURL.path): \(error). Attempting recovery.")
                self.removeLoadedStores()
                Self.destroySQLiteStoreFiles(at: storeURL)
                self.container.persistentStoreDescriptions = [Self.makeDescription(url: storeURL)]
                self.loadStores(storeURL: storeURL, attempt: .recovered)

            case .recovered:
                // Deliberately no in-memory fallback. An NSInMemoryStoreType
                // store accepts writes and reports success while persisting
                // nothing, so every dictation would look saved and vanish on
                // quit. AppState keeps its own session-local history array, so
                // the fallback bought no functionality — only a false
                // durability signal. Failing here makes writes return
                // PipelineHistoryStoreUnavailableError, which callers surface.
                print("[PipelineHistoryStore] Recovery failed: \(error). History persistence is disabled for this launch.")
                self.removeLoadedStores()
                self.finishLoading(.failed)
            }
        }
    }

    private func removeLoadedStores() {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private func finishLoading(_ state: StoreState) {
        storeState.withLock { $0 = state }
        // Release everything that queued up while the store was opening.
        workQueue.isSuspended = false
    }

    private var isStoreUsable: Bool {
        storeState.withLock { $0 == .loaded }
    }

    /// Enqueues `work` on the store's serial queue. `completion` always runs, on
    /// the main queue — with an explicit failure if the store never loaded, so
    /// callers can tell "nothing persisted" apart from "nothing to persist".
    private func perform<T>(
        _ work: @escaping (NSManagedObjectContext) throws -> T,
        completion: ((Result<T, Error>) -> Void)?
    ) {
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            guard self.isStoreUsable else {
                if let completion {
                    DispatchQueue.main.async {
                        completion(.failure(PipelineHistoryStoreUnavailableError()))
                    }
                }
                return
            }
            let context = self.writeContext
            var result: Result<T, Error>
            do {
                var value: T?
                var thrown: Error?
                context.performAndWait {
                    do {
                        value = try work(context)
                    } catch {
                        context.rollback()
                        thrown = error
                    }
                }
                if let thrown { throw thrown }
                result = .success(value!)
            } catch {
                result = .failure(error)
            }
            if let completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Like ``perform``, but runs `completion` on the store's serial queue
    /// instead of hopping to main — so the caller's work is serialized against
    /// every other store operation.
    private func performOnStoreQueue<T>(
        _ work: @escaping (NSManagedObjectContext) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            guard self.isStoreUsable else {
                completion(.failure(PipelineHistoryStoreUnavailableError()))
                return
            }
            let context = self.writeContext
            var result: Result<T, Error>
            do {
                var value: T?
                var thrown: Error?
                context.performAndWait {
                    do {
                        value = try work(context)
                    } catch {
                        context.rollback()
                        thrown = error
                    }
                }
                if let thrown { throw thrown }
                result = .success(value!)
            } catch {
                result = .failure(error)
            }
            completion(result)
        }
    }

    // MARK: - Reads

    /// Loads history off the main thread and delivers the result on the main
    /// queue. Used at launch so the (potentially several-MB) base64 screenshot
    /// payloads aren't materialized synchronously on the main thread during
    /// app startup. The screenshot column is excluded from the fetch entirely
    /// (see ``excludeScreenshotPayload``) and loaded lazily per row only when a
    /// run-log entry is expanded (see ``loadScreenshotDataURL``).
    /// Delivers a `Result` rather than collapsing failures to an empty list: a
    /// transient fetch error is not the same as "there is no history", and a
    /// caller that treats it as one will erase valid in-memory state.
    func loadAllHistoryAsync(completion: @escaping (Result<[PipelineHistoryItem], Error>) -> Void) {
        perform({ context in
            let request = Self.bulkHistoryRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            let rows = try context.fetch(request)
            return rows.compactMap { Self.makeHistoryItem(fromRow: $0) }
        }, completion: completion)
    }

    /// Fetches a single run's base64 screenshot `data:` URL on demand. Returns
    /// `nil` if the store isn't loaded, the entry is gone, or it has no
    /// screenshot. Always delivers on the main queue.
    func loadScreenshotDataURL(forID id: UUID, completion: @escaping (String?) -> Void) {
        perform({ context in
            let request = Self.pipelineHistoryRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            return try context.fetch(request).first?.contextScreenshotDataURL
        }, completion: { result in
            switch result {
            case .success(let dataURL):
                completion(dataURL)
            case .failure(let error):
                print("[PipelineHistoryStore] Screenshot load failed: \(error)")
                completion(nil)
            }
        })
    }

    /// Runs `body` **on the store's serial queue** with the set of audio
    /// filenames currently referenced by history rows.
    ///
    /// Used by the orphan sweep. Delivering on the store queue rather than
    /// hopping to main is the point: it holds the queue for the duration of
    /// `body`, so an `append` cannot commit a new row (and its freshly copied
    /// WAV) while the sweep is deciding what to delete. Fetching the set and
    /// then scanning on a different queue would leave exactly that window open.
    func withReferencedAudioFileNames(_ body: @escaping (Result<Set<String>, Error>) -> Void) {
        performOnStoreQueue({ context in
            let request = Self.audioFileNameRequest()
            return Set(try context.fetch(request).compactMap { $0["audioFileName"] as? String })
        }, completion: body)
    }

    // MARK: - Mutations

    /// Inserts `item`, then trims to `maxCount`. Delivers the audio filenames of
    /// dropped entries so the caller can remove them from disk.
    ///
    /// A `.failure` here means the row did **not** land — the caller relies on
    /// that to decide the copied audio file is orphaned. A trim that fails after
    /// the row committed is therefore reported through
    /// ``PipelineHistoryAppendResult/trimError`` instead, not as a failure and
    /// not silently.
    func append(
        _ item: PipelineHistoryItem,
        maxCount: Int,
        completion: ((Result<PipelineHistoryAppendResult, Error>) -> Void)? = nil
    ) {
        perform({ context in
            try Self.insert(item, into: context)
            try Self.save(context)
            do {
                let dropped = try Self.trim(to: maxCount, in: context)
                try Self.save(context)
                return PipelineHistoryAppendResult(droppedAudioFileNames: dropped, trimError: nil)
            } catch {
                context.rollback()
                return PipelineHistoryAppendResult(droppedAudioFileNames: [], trimError: error)
            }
        }, completion: completion)
    }

    func update(_ item: PipelineHistoryItem, completion: ((Result<Void, Error>) -> Void)? = nil) {
        perform({ context in
            let request = Self.pipelineHistoryRequest()
            request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
            request.fetchLimit = 1
            guard let entity = try context.fetch(request).first else { return }
            entity.intent = item.intent.rawValue
            entity.selectedText = item.selectedText
            entity.capturedSelection = item.capturedSelection
            entity.rawTranscript = item.rawTranscript
            entity.postProcessedTranscript = item.postProcessedTranscript
            entity.postProcessingPrompt = item.postProcessingPrompt
            entity.systemPrompt = item.systemPrompt
            entity.contextSystemPrompt = item.contextSystemPrompt
            entity.postProcessingStatus = item.postProcessingStatus
            entity.debugStatus = item.debugStatus
            entity.contextAppName = item.contextAppName
            entity.contextBundleIdentifier = item.contextBundleIdentifier
            entity.contextWindowTitle = item.contextWindowTitle
            try Self.save(context)
        }, completion: completion)
    }

    func delete(id: UUID, completion: ((Result<String?, Error>) -> Void)? = nil) {
        perform({ context in
            let request = Self.pipelineHistoryRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            // Deleting needs the managed object itself, so this row is read in
            // full — screenshot column included. Bounded to one row by
            // `fetchLimit`, unlike the bulk readers, which fetch dictionaries
            // precisely so they can leave that column in SQLite.
            request.returnsObjectsAsFaults = false
            guard let entity = try context.fetch(request).first else { return nil }
            let audioFileName = entity.audioFileName
            context.delete(entity)
            try Self.save(context)
            return audioFileName
        }, completion: completion)
    }

    func clearAll(completion: ((Result<[String], Error>) -> Void)? = nil) {
        perform({ context in
            // Dictionary fetch, not managed objects: the batch delete below
            // removes the rows without them, so materializing every entry —
            // each carrying up to 500 KB of base64 screenshot — to read one
            // string column off it would be the whole store loaded for nothing.
            let names = try Self.referencedAudioFileNames(in: context)
            let deleteRequest = NSBatchDeleteRequest(
                fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: Self.entityName)
            )
            deleteRequest.resultType = .resultTypeObjectIDs
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            // A batch delete goes straight to SQLite, so in-memory contexts must
            // be told what changed.
            if let objectIDs = result?.result as? [NSManagedObjectID], !objectIDs.isEmpty {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                    into: [context, self.container.viewContext]
                )
            }
            return names
        }, completion: completion)
    }

    func trim(to maxCount: Int, completion: ((Result<[String], Error>) -> Void)? = nil) {
        perform({ context in
            let dropped = try Self.trim(to: maxCount, in: context)
            try Self.save(context)
            return dropped
        }, completion: completion)
    }

    // MARK: - Context-bound primitives

    /// Deletes everything past the newest `maxCount` entries and returns their
    /// audio filenames.
    ///
    /// The fetch has to return managed objects — `context.delete` needs them —
    /// so it does read every column, screenshot included. What keeps that cheap
    /// is `fetchOffset`: the request only ever matches the rows being dropped,
    /// which on the append path is zero or one.
    private static func trim(to maxCount: Int, in context: NSManagedObjectContext) throws -> [String] {
        try deleteEntries(in: context, droppingFirst: max(maxCount, 0))
    }

    /// Every audio filename referenced by history, without materializing rows.
    private static func referencedAudioFileNames(in context: NSManagedObjectContext) throws -> [String] {
        try context.fetch(audioFileNameRequest()).compactMap { $0["audioFileName"] as? String }
    }

    /// Deletes every entry past the newest `offset` and returns their audio
    /// filenames, so the caller can remove the files too.
    private static func deleteEntries(
        in context: NSManagedObjectContext,
        droppingFirst offset: Int
    ) throws -> [String] {
        let request = pipelineHistoryRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.returnsObjectsAsFaults = false
        request.fetchBatchSize = 20
        if offset > 0 {
            request.fetchOffset = offset
        }
        let entities = try context.fetch(request)
        let names = entities.compactMap(\.audioFileName)
        for entity in entities {
            context.delete(entity)
        }
        return names
    }

    private static func insert(_ item: PipelineHistoryItem, into context: NSManagedObjectContext) throws {
        let entity = PipelineHistoryEntry(context: context)
        entity.id = item.id
        entity.intent = item.intent.rawValue
        entity.selectedText = item.selectedText
        entity.capturedSelection = item.capturedSelection
        entity.timestamp = item.timestamp
        entity.rawTranscript = item.rawTranscript
        entity.postProcessedTranscript = item.postProcessedTranscript
        entity.postProcessingPrompt = item.postProcessingPrompt
        entity.systemPrompt = item.systemPrompt
        entity.contextSummary = item.contextSummary
        entity.contextSystemPrompt = item.contextSystemPrompt
        entity.contextPrompt = item.contextPrompt
        entity.contextScreenshotDataURL = item.contextScreenshotDataURL
        entity.contextScreenshotStatus = item.contextScreenshotStatus
        entity.postProcessingStatus = item.postProcessingStatus
        entity.debugStatus = item.debugStatus
        entity.customVocabulary = item.customVocabulary
        entity.audioFileName = item.audioFileName
        entity.contextAppName = item.contextAppName
        entity.contextBundleIdentifier = item.contextBundleIdentifier
        entity.contextWindowTitle = item.contextWindowTitle
    }

    private static func save(_ context: NSManagedObjectContext) throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    /// Drops every decoded managed object, releasing the row cache. Called on
    /// memory pressure.
    func releaseCachedObjects() {
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            self.writeContext.performAndWait { self.writeContext.reset() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.container.viewContext.reset()
        }
    }

    /// A fetch returning raw rows for every attribute *except* the heavy base64
    /// screenshot, so listing history never reads the screenshot blobs out of
    /// SQLite.
    ///
    /// The dictionary result type is what makes the exclusion real:
    /// `propertiesToFetch` applies only to dictionary fetches. A
    /// managed-object fetch ignores it and still `SELECT`s every column, so the
    /// screenshot payload came back regardless — the cost this is here to avoid.
    private static func bulkHistoryRequest() -> NSFetchRequest<NSDictionary> {
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = bulkFetchPropertyNames
        return request
    }

    /// A fetch returning just the audio filename column, for the orphan sweep.
    private static func audioFileNameRequest() -> NSFetchRequest<NSDictionary> {
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["audioFileName"]
        return request
    }

    /// All persisted attributes except `contextScreenshotDataURL`.
    private static let bulkFetchPropertyNames: [String] = [
        "intent", "selectedText", "capturedSelection", "id", "timestamp",
        "rawTranscript", "postProcessedTranscript", "postProcessingPrompt",
        "systemPrompt", "contextSummary", "contextSystemPrompt", "contextPrompt",
        "contextScreenshotStatus", "postProcessingStatus", "debugStatus",
        "customVocabulary", "audioFileName", "contextAppName",
        "contextBundleIdentifier", "contextWindowTitle"
    ]

    fileprivate static let entityName = "PipelineHistoryEntry"

    private static func pipelineHistoryRequest() -> NSFetchRequest<PipelineHistoryEntry> {
        NSFetchRequest<PipelineHistoryEntry>(entityName: entityName)
    }

    private static func destroySQLiteStoreFiles(at storeURL: URL) {
        let basePath = storeURL.path
        let fileManager = FileManager.default
        for path in [basePath, basePath + "-wal", basePath + "-shm"] {
            try? fileManager.removeItem(atPath: path)
        }
    }

    /// Builds an item from a ``bulkHistoryRequest`` row. `contextScreenshotDataURL`
    /// is always `nil` — that column is deliberately not part of the fetch, and
    /// is loaded per row on demand by ``loadScreenshotDataURL(forID:completion:)``.
    ///
    /// Returns `nil` for a row without an `id`, which no row this store writes
    /// can be (the attribute is non-optional), rather than inventing one.
    private static func makeHistoryItem(fromRow row: NSDictionary) -> PipelineHistoryItem? {
        guard let id = row["id"] as? UUID else { return nil }
        return PipelineHistoryItem(
            intent: PipelineHistoryItemIntent(rawValue: row["intent"] as? String ?? "") ?? .dictation,
            selectedText: row["selectedText"] as? String,
            capturedSelection: row["capturedSelection"] as? String,
            id: id,
            timestamp: row["timestamp"] as? Date ?? Date(),
            rawTranscript: row["rawTranscript"] as? String ?? "",
            postProcessedTranscript: row["postProcessedTranscript"] as? String ?? "",
            postProcessingPrompt: row["postProcessingPrompt"] as? String,
            systemPrompt: row["systemPrompt"] as? String,
            contextSummary: row["contextSummary"] as? String ?? "",
            contextSystemPrompt: row["contextSystemPrompt"] as? String,
            contextPrompt: row["contextPrompt"] as? String,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: row["contextScreenshotStatus"] as? String ?? "available (image)",
            postProcessingStatus: row["postProcessingStatus"] as? String ?? "",
            debugStatus: row["debugStatus"] as? String ?? "",
            customVocabulary: row["customVocabulary"] as? String ?? "",
            audioFileName: row["audioFileName"] as? String,
            contextAppName: row["contextAppName"] as? String,
            contextBundleIdentifier: row["contextBundleIdentifier"] as? String,
            contextWindowTitle: row["contextWindowTitle"] as? String
        )
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = Self.entityName
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)

        entity.properties = [
            makeAttribute(name: "intent", type: .stringAttributeType, isOptional: true, defaultValue: "dictation"),
            makeAttribute(name: "selectedText", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "capturedSelection", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "systemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextSummary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "contextSystemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotDataURL", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "debugStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customVocabulary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextAppName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextBundleIdentifier", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextWindowTitle", type: .stringAttributeType, isOptional: true)
        ]

        // Indexes on the only two columns any query uses. Without these,
        // SQLite answers `ORDER BY timestamp` with a full SCAN plus a temp
        // B-tree, and `WHERE id == ?` with a full SCAN — verified with
        // EXPLAIN QUERY PLAN against a live store. Cheap to add, and it stops
        // the cost scaling if maxPipelineHistoryCount ever rises.
        let attributesByName = Dictionary(
            uniqueKeysWithValues: entity.properties.compactMap { property -> (String, NSAttributeDescription)? in
                guard let attribute = property as? NSAttributeDescription else { return nil }
                return (attribute.name, attribute)
            }
        )
        var indexes: [NSFetchIndexDescription] = []
        if let timestamp = attributesByName["timestamp"] {
            let element = NSFetchIndexElementDescription(property: timestamp, collationType: .binary)
            element.isAscending = false
            indexes.append(NSFetchIndexDescription(name: "byTimestamp", elements: [element]))
        }
        if let id = attributesByName["id"] {
            let element = NSFetchIndexElementDescription(property: id, collationType: .binary)
            indexes.append(NSFetchIndexDescription(name: "byID", elements: [element]))
        }
        entity.indexes = indexes

        model.entities = [entity]
        return model
    }

    private static func makeAttribute(
        name: String,
        type: NSAttributeType,
        isOptional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var audioFileName: String?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
}
