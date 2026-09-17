import SwiftUI

struct ProgressBarView: View {
    let progress: Double
    let height: CGFloat = 8

    private var progressColor: Color {
        StatusLevel(usagePercent: progress).color
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.divider)
                    .frame(height: height)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(progressColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(progress / 100)), height: height)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: height)
    }
}

#Preview {
    VStack(spacing: 20) {
        ProgressBarView(progress: 25)
        ProgressBarView(progress: 60)
        ProgressBarView(progress: 85)
    }
    .padding()
    .background(Theme.background)
}
