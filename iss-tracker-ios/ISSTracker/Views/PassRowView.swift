import SwiftUI

struct PassRowView: View {
    let pass: ISSPass

    private var timeUntilText: String {
        let sec = pass.start.timeIntervalSinceNow
        if sec < 0           { return "Now" }
        if sec < 60          { return "< 1 min" }
        if sec < 3600        { return "\(Int(sec/60)) min" }
        let h = Int(sec/3600); let m = Int(sec.truncatingRemainder(dividingBy: 3600)/60)
        return "\(h)h \(m)m"
    }

    private var qualityColor: Color {
        switch pass.quality {
        case .excellent: return .green
        case .good:      return .blue
        case .fair:      return .orange
        }
    }

    private var qualityStars: String {
        switch pass.quality {
        case .excellent: return "★★★"
        case .good:      return "★★"
        case .fair:      return "★"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Row 1: Date / time + countdown
            HStack {
                Text(pass.start, style: .date)
                    .font(.subheadline.weight(.semibold))
                Text(pass.start, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeUntilText)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(qualityColor.opacity(0.15))
                    .foregroundStyle(qualityColor)
                    .clipShape(Capsule())
            }

            // Row 2: Direction + elevation + duration
            HStack(spacing: 16) {
                Label("\(pass.startCompass) → \(pass.endCompass)", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(String(format: "%.0f°", pass.maxElevation), systemImage: "arrow.up")
                    .font(.caption)
                    .foregroundStyle(qualityColor)

                Label(durationText, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(qualityStars)
                    .foregroundStyle(qualityColor)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .fill(qualityColor)
                .frame(width: 3),
            alignment: .leading
        )
        .padding(.leading, 8)
    }

    private var durationText: String {
        let s = Int(pass.duration)
        return s >= 60 ? "\(s/60)m \(s%60)s" : "\(s)s"
    }
}

#if DEBUG
#Preview {
    List {
        PassRowView(pass: ISSPass(
            start: Date().addingTimeInterval(3660),
            peak: Date().addingTimeInterval(3850),
            end: Date().addingTimeInterval(4020),
            maxElevation: 67,
            startAzimuth: 210,
            peakAzimuth: 180,
            endAzimuth: 30
        ))
        PassRowView(pass: ISSPass(
            start: Date().addingTimeInterval(90000),
            peak: Date().addingTimeInterval(90200),
            end: Date().addingTimeInterval(90350),
            maxElevation: 22,
            startAzimuth: 60,
            peakAzimuth: 90,
            endAzimuth: 150
        ))
    }
}
#endif
