//
//  TolanPlusPaywallView.swift
//  DemoModule
//

import SwiftUI

struct TolanPlusPaywallView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)

            Text("Tolan Plus")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Unlock all premium features")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            PlusSubscriptionOptionRow(
                period: "Yearly",
                price: "$79.99",
                detail: "$6.67/month • Best Value"
            )

            Button(action: {}) {
                Text("Get Tolan Plus")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}

private struct PlusSubscriptionOptionRow: View {
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
                .stroke(Color.blue, lineWidth: 2)
        )
    }
}

struct TolanPlusPaywallView_Previews: PreviewProvider {
    static var previews: some View {
        TolanPlusPaywallView()
            .previewDisplayName("Tolan Plus - Yearly $79.99")
            .previewLayout(.sizeThatFits)
    }
}
