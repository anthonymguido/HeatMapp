import SwiftUI
import UIKit

/// Saves surveys as JSON plus one floor-plan image per survey in the app's Documents folder.
@MainActor
final class SurveyStore: ObservableObject {
    @Published private(set) var surveys: [Survey] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("surveys.json") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Surveys", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func survey(_ id: UUID) -> Survey? {
        surveys.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> Survey {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let survey = Survey(name: trimmed.isEmpty ? "Untitled survey" : trimmed)
        surveys.insert(survey, at: 0)
        save()
        return survey
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { removeFloorPlanFile(of: surveys[i]) }
        surveys.remove(atOffsets: offsets)
        save()
    }

    func mutate(_ id: UUID, _ change: (inout Survey) -> Void) {
        guard let i = surveys.firstIndex(where: { $0.id == id }) else { return }
        change(&surveys[i])
        save()
    }

    func setFloorPlan(_ image: UIImage, for id: UUID) {
        guard let survey = survey(id),
              let data = image.normalizedForFloorPlan().jpegData(compressionQuality: 0.9) else { return }
        let name = "floorplan-\(UUID().uuidString).jpg"
        do {
            try data.write(to: root.appendingPathComponent(name), options: .atomic)
        } catch {
            print("Failed to save floor plan: \(error)")
            return
        }
        removeFloorPlanFile(of: survey)
        mutate(id) { $0.floorPlanFile = name }
    }

    func floorPlanImage(for survey: Survey) -> UIImage? {
        guard let file = survey.floorPlanFile else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent(file).path)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        surveys = (try? decoder.decode([Survey].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(surveys).write(to: indexURL, options: .atomic)
        } catch {
            print("Failed to save surveys: \(error)")
        }
    }

    private func removeFloorPlanFile(of survey: Survey) {
        guard let file = survey.floorPlanFile else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
    }
}

extension UIImage {
    /// Redraws upright (fixes EXIF orientation), on white, capped at `maxDimension` pixels.
    func normalizedForFloorPlan(maxDimension: CGFloat = 3000) -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func blankGrid(size: CGSize = CGSize(width: 1600, height: 1200), spacing: CGFloat = 50) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setLineWidth(1)
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                cg.setStrokeColor((i % 4 == 0 ? UIColor.systemGray3 : UIColor.systemGray5).cgColor)
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)); cg.strokePath()
                x += spacing; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                cg.setStrokeColor((i % 4 == 0 ? UIColor.systemGray3 : UIColor.systemGray5).cgColor)
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); cg.strokePath()
                y += spacing; i += 1
            }
        }
    }
}
