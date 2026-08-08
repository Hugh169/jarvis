import Testing
import JarvisCore
@testable import JarvisTools

@Suite("Confirmation details")
struct ConfirmationDetailsTests {
    @Test("Recipient sorts above the body, so you read who before what")
    func ordersByWhatMattersFirst() {
        let rows = ConfirmationDetails.rows(from: .object([
            "body": .string("Running late."),
            "subject": .string("Tonight"),
            "to": .string("dad@example.com"),
        ]))
        #expect(rows.map(\.label) == ["To", "Subject", "Body"])
    }

    @Test("Unknown arguments still appear, after the known ones")
    func keepsUnknownArguments() {
        let rows = ConfirmationDetails.rows(from: .object([
            "to": .string("dad@example.com"),
            "reply_to_id": .string("abc123"),
            "cc": .string("mum@example.com"),
        ]))
        #expect(rows.first?.label == "To")
        // Alphabetical among themselves, so the order is stable between turns.
        #expect(rows.dropFirst().map(\.label) == ["Cc", "Reply to id"])
    }

    @Test("A long body is shown in full, not clipped to a preview")
    func keepsLongValues() {
        let body = String(repeating: "a", count: 1_000)
        let rows = ConfirmationDetails.rows(from: .object(["body": .string(body)]))
        #expect(rows.first?.value.count == 1_000)
    }

    @Test("A runaway value is cut where no one would read anyway")
    func boundsAbsurdValues() {
        let rows = ConfirmationDetails.rows(from: .object([
            "body": .string(String(repeating: "a", count: 50_000)),
        ]))
        #expect(rows.first?.value.count == ConfirmationDetails.valueLimit)
    }

    @Test("Non-string arguments are summarised, never silently dropped")
    func summarisesStructuredValues() {
        let rows = ConfirmationDetails.rows(from: .object([
            "count": .number(3),
            "urgent": .bool(true),
            "attachments": .array([.string("a"), .string("b")]),
            "headers": .object(["x": .string("y")]),
        ]))
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["Count"] == "3")
        #expect(byLabel["Urgent"] == "yes")
        #expect(byLabel["Attachments"] == "2 items")
        #expect(byLabel["Headers"] == "1 field")
    }

    @Test("Null arguments are the one thing dropped — there is nothing to show")
    func dropsNulls() {
        let rows = ConfirmationDetails.rows(from: .object([
            "to": .string("dad@example.com"),
            "cc": .null,
        ]))
        #expect(rows.map(\.label) == ["To"])
    }

    @Test("A call with no arguments produces no rows rather than an empty box")
    func handlesEmptyInput() {
        #expect(ConfirmationDetails.rows(from: .object([:])).isEmpty)
        #expect(ConfirmationDetails.rows(from: .null).isEmpty)
    }
}
