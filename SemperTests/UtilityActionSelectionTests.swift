import Testing

@testable import Semper

@Suite("Action search selection")
struct UtilityActionSelectionTests {
    private let first = UtilityActionID(rawValue: "sound.first")
    private let second = UtilityActionID(rawValue: "awake.second")
    private let third = UtilityActionID(rawValue: "shelf.third")

    @Test func retainedQueriesAndChangedModulesReconcileSelection() {
        #expect(UtilityActionSelection.reconciled(nil, among: [first, second]) == first)
        #expect(UtilityActionSelection.reconciled(second, among: [first, second]) == second)
        #expect(UtilityActionSelection.reconciled(first, among: [second, third]) == second)
        #expect(UtilityActionSelection.reconciled(first, among: []) == nil)
    }

    @Test func arrowsMoveThroughResultsAndStopAtEdges() {
        let ids = [first, second, third]
        #expect(UtilityActionSelection.moved(from: first, by: 1, among: ids) == second)
        #expect(UtilityActionSelection.moved(from: third, by: -1, among: ids) == second)
        #expect(UtilityActionSelection.moved(from: first, by: -1, among: ids) == first)
        #expect(UtilityActionSelection.moved(from: third, by: 1, among: ids) == third)
    }

    @Test func missingSelectionStartsAtTheAppropriateEdge() {
        let ids = [first, second, third]
        #expect(UtilityActionSelection.moved(from: nil, by: 1, among: ids) == first)
        #expect(UtilityActionSelection.moved(from: nil, by: -1, among: ids) == third)
        #expect(UtilityActionSelection.moved(from: first, by: 1, among: [second, third]) == second)
    }

    @Test func emptyAndSingleResultQueriesRemainSafe() {
        #expect(UtilityActionSelection.moved(from: first, by: 1, among: []) == nil)
        #expect(UtilityActionSelection.moved(from: first, by: -1, among: [first]) == first)
        #expect(UtilityActionSelection.moved(from: first, by: 1, among: [first]) == first)
    }
}
