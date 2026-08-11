import SwiftUI

struct WorkoutListView: View {
    let records: [WorkoutRecord]

    var body: some View {
        List(records) { record in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.activityName)
                        .font(.headline)
                    Spacer()
                    if record.hasRoute {
                        Label("\(record.pointCount)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Label("No GPS", systemImage: "location.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(Formatters.dateTime(record.start))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text(Formatters.duration(record.duration))
                    if let distance = record.healthKitDistance {
                        Text(Formatters.distance(distance))
                    }
                    if record.hasRoute {
                        Text("route \(Formatters.distance(record.track.distance))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
