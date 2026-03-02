//
//  TolanLitePaywallView.swift
//  DemoModule
//

import SwiftUI

struct TolanLitePaywallView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundColor(.purple)

            Text("Tolan Lite")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Essential features at a great price")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            LiteSubscriptionOptionRow(
                period: "Yearly",
                price: "$39.99",
                detail: "$3.33/month • Best Value"
            )

            Button(action: {}) {
                Text("Get Tolan Lite")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}

private struct LiteSubscriptionOptionRow: View {
    var period: String
    var price: String
    var detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(period)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(price)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding()
        .background(Color(PlatformColor.systemGray6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple, lineWidth: 2)
        )
    }
}

struct TolanLitePaywallView_Previews: PreviewProvider {
    static var previews: some View {
        TolanLitePaywallView()
            .previewDisplayName("Tolan Lite - Yearly $39.99")
            .previewLayout(.sizeThatFits)
    }
}
