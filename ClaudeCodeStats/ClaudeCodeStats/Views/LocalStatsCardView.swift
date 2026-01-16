import SwiftUI

struct LocalStatsCardView: View {
    let title: String
    let value: String
    let subtitle: String?

    private var cardBackground: Color {
        Color(red: 42/255, green: 42/255, blue: 42/255)
    }

    private var textSecondary: Color {
        Color(red: 138/255, green: 138/255, blue: 138/255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(textSecondary)

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(cardBackground)
        .cornerRadius(8)
    }
}

#Preview {
    HStack {
        LocalStatsCardView(title: "Today", value: "245", subtitle: "messages")
        LocalStatsCardView(title: "This Week", value: "1,832", subtitle: "messages")
    }
    .padding()
    .background(Color(red: 26/255, green: 26/255, blue: 26/255))
}
