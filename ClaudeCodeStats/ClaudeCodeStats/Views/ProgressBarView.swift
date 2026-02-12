import SwiftUI

struct ProgressBarView: View {
    let progress: Double
    let height: CGFloat = 8

    private var progressColor: Color {
        if progress < 50 {
            return Color(red: 74/255, green: 222/255, blue: 128/255) // Green
        } else if progress < 75 {
            return Color(red: 250/255, green: 204/255, blue: 21/255) // Yellow
        } else {
            return Color(red: 248/255, green: 113/255, blue: 113/255) // Red
        }
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
