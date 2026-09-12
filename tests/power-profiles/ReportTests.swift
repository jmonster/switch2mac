import Foundation

@main enum ReportTests {
    static func main() throws {
        let expected = CommandLine.arguments[1]
        let data = try SensorProfileReport.data(revision: "identifier /Users/private")
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(value["selected_profile"] as? String == expected)
        precondition(value["source_revision"] as? String == "unknown")
        precondition(value["hardware_qualification"] as? String == "not-run")
        precondition(value["energy_measurement"] as? String == "not-run")
        let models = value["models"] as! [[String: Any]]
        precondition(models.count == Switch2.Model.allCases.count)
        for (model, output) in zip(Switch2.Model.allCases, models) {
            precondition(output["feature_mask"] as? String == String(format: "%02x", Switch2.Feature.flags(for: model, profile: ApplicationSensorPolicy.selectedProfile)))
        }
        print("PASS configuration-only profile description " + expected)
    }
}
