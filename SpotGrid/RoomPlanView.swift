//
//  RoomPlanView.swift
//  MicroLocator
//
//  Renders a 2D mini-map floor plan from RoomPlan's CapturedRoom data.
//

import SwiftUI
import RoomPlan
import simd

struct RoomPlanView: View {
    let capturedRoomData: Data
    
    @State private var room: CapturedRoom?
    
    var body: some View {
        ZStack {
            if let room = room {
                GeometryReader { proxy in
                    Canvas { context, size in
                        drawRoom(room, in: &context, size: size)
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .background(Color.black.opacity(0.4))
        .task {
            if let decoded = try? JSONDecoder().decode(CapturedRoom.self, from: capturedRoomData) {
                self.room = decoded
            }
        }
    }
    
    private func drawRoom(_ room: CapturedRoom, in context: inout GraphicsContext, size: CGSize) {
        var minX: Float = .infinity, maxX: Float = -.infinity
        var minZ: Float = .infinity, maxZ: Float = -.infinity
        
        let allElements: [CapturedRoom.Surface] = room.walls + room.windows + room.doors
        var hasElements = false
        
        for el in allElements {
            let x = el.transform.columns.3.x
            let z = el.transform.columns.3.z
            minX = min(minX, x)
            maxX = max(maxX, x)
            minZ = min(minZ, z)
            maxZ = max(maxZ, z)
            hasElements = true
        }
        
        for obj in room.objects {
            let x = obj.transform.columns.3.x
            let z = obj.transform.columns.3.z
            minX = min(minX, x)
            maxX = max(maxX, x)
            minZ = min(minZ, z)
            maxZ = max(maxZ, z)
            hasElements = true
        }
        
        guard hasElements else { return }
        
        let width = CGFloat(maxX - minX)
        let height = CGFloat(maxZ - minZ)
        
        // Prevent division by zero
        guard width > 0 && height > 0 else { return }
        
        let scale = min(size.width / (width + 2), size.height / (height + 2)) // padding
        
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -CGFloat(minX + maxX)/2, y: -CGFloat(minZ + maxZ)/2)
        
        // Draw Walls
        for wall in room.walls {
            drawSurface(wall, color: .white.opacity(0.9), thickness: 0.1, in: &context)
        }
        
        // Draw Doors/Windows
        for door in room.doors {
            drawSurface(door, color: .green.opacity(0.6), thickness: 0.05, in: &context)
        }
        for window in room.windows {
            drawSurface(window, color: .cyan.opacity(0.6), thickness: 0.05, in: &context)
        }
        
        // Draw Objects (Furniture)
        for obj in room.objects {
            let x = CGFloat(obj.transform.columns.3.x)
            let z = CGFloat(obj.transform.columns.3.z)
            let w = CGFloat(obj.dimensions.x)
            let d = CGFloat(obj.dimensions.z)
            
            // X column of transform gives the local X axis in world space
            let angle = atan2(CGFloat(obj.transform.columns.0.z), CGFloat(obj.transform.columns.0.x))
            
            var rectPath = Path(CGRect(x: -w/2, y: -d/2, width: w, height: d))
            rectPath = rectPath.applying(CGAffineTransform(rotationAngle: angle))
            rectPath = rectPath.applying(CGAffineTransform(translationX: x, y: z))
            
            context.fill(rectPath, with: .color(.blue.opacity(0.5)))
            context.stroke(rectPath, with: .color(.blue), lineWidth: 0.05)
        }
    }
    
    private func drawSurface(_ surface: CapturedRoom.Surface, color: Color, thickness: CGFloat, in context: inout GraphicsContext) {
        let x = CGFloat(surface.transform.columns.3.x)
        let z = CGFloat(surface.transform.columns.3.z)
        let length = CGFloat(surface.dimensions.x)
        
        let angle = atan2(CGFloat(surface.transform.columns.0.z), CGFloat(surface.transform.columns.0.x))
        
        var rectPath = Path(CGRect(x: -length/2, y: -thickness/2, width: length, height: thickness))
        rectPath = rectPath.applying(CGAffineTransform(rotationAngle: angle))
        rectPath = rectPath.applying(CGAffineTransform(translationX: x, y: z))
        
        context.fill(rectPath, with: .color(color))
    }
}
