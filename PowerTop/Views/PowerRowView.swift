import SwiftUI

struct PowerRowView: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer()

            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}
