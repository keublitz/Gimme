// sam wiener 2026, all rights reserved

import SwiftUI

extension BinaryFloatingPoint {
    func remaining() -> String {
        let hours = Int(self / 3600)
        let hoursString = String(format: "%d", hours)
        let minutes = Int(self / 60) % 60
        let minutesSingle = String(minutes)
        let minutesString = String(format: "%d", minutes)
        let seconds = Int(self.truncatingRemainder(dividingBy: 60))
        let secondsString = String(format: "%d", seconds)
        
        let zeroHours: Bool = hours == 0
        let zeroMinutes: Bool = minutes == 0 || (self / 60).truncatingRemainder(dividingBy: 60) == 0
        let zeroSeconds: Bool = seconds == 0
        
        switch (zeroHours, zeroMinutes) {
        case (false, false): return "\(hours)h \(minutesString)m \(secondsString)s"
        case (false, true): return "\(hours)h \(secondsString)s"
        case (true, false): return "\(minutesSingle)m \(secondsString)s"
        case (true, true): return "\(secondsString)s"
        }
    }
}

func parseTimeToSeconds(_ str: String) -> Double? {
    let parts = str.split(separator: ":").map(String.init)
    guard parts.count == 3,
          let hours = Double(parts[0]),
          let minutes = Double(parts[1]),
          let seconds = Double(parts[2]) else { return nil }
    
    return hours * 3600 + minutes * 60 + seconds
}
