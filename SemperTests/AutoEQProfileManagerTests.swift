import Testing
@testable import Semper

@Suite("AutoEQ profile manager")
@MainActor
struct AutoEQProfileManagerTests {
    @Test("Catalog loading is lazy by default")
    func catalogLoadingIsLazyByDefault() async {
        var loadCount = 0
        let manager = AutoEQProfileManager(catalogLoadOperation: {
            loadCount += 1
            return true
        })

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(loadCount == 0)
        #expect(manager.catalogState == .idle)
    }

    @Test("Concurrent catalog preparation performs one load")
    func concurrentCatalogPreparationPerformsOneLoad() async {
        var loadCount = 0
        let manager = AutoEQProfileManager(catalogLoadOperation: {
            loadCount += 1
            for _ in 0..<10 {
                await Task.yield()
            }
            return true
        })

        let first = Task { @MainActor in
            await manager.prepareCatalogIfNeeded()
        }
        await Task.yield()
        let second = Task { @MainActor in
            await manager.prepareCatalogIfNeeded()
        }

        await first.value
        await second.value
        await manager.prepareCatalogIfNeeded()

        #expect(loadCount == 1)
    }

    @Test("Resolving an uncached saved ID prepares the catalog")
    func resolvingUncachedSavedIDPreparesCatalog() async {
        var loadCount = 0
        let manager = AutoEQProfileManager(catalogLoadOperation: {
            loadCount += 1
            return true
        })

        let profile = await manager.resolveProfile(for: "missing-profile")

        #expect(profile == nil)
        #expect(loadCount == 1)
    }

    @Test("Failed catalog preparation can be retried")
    func failedCatalogPreparationCanBeRetried() async {
        var loadCount = 0
        let manager = AutoEQProfileManager(catalogLoadOperation: {
            loadCount += 1
            return loadCount > 1
        })

        await manager.prepareCatalogIfNeeded()
        await manager.prepareCatalogIfNeeded()
        await manager.prepareCatalogIfNeeded()

        #expect(loadCount == 2)
    }
}
