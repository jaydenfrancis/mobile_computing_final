//
//  StartView.swift
//  roboflow_test
//
//  Created by Jayden Francis on 5/13/24.
//
import Foundation
import SwiftUI

struct StartView: View {
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.black, Color.gray.opacity(0.5)]), startPoint: .top, endPoint: .bottom)
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    Spacer()
                    
                    Image(systemName: "suit.spade.fill")
                        .font(.system(size: 100))
                        .foregroundColor(.white)
                    
                    Text("Beat the House")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.bottom, 20)
                    
                    NavigationLink(destination: ContentView()) {
                        Text("Start")
                            .foregroundColor(.white)
                            .frame(width: 200, height: 50)
                            .background(Color.green.opacity(0.85))
                            .cornerRadius(25)
                            .shadow(radius: 10)
                            .padding()
                    }
                    
                    Spacer()
                }
            }
            .navigationTitle("Home")
            .navigationBarHidden(true)
        }
    }
}
