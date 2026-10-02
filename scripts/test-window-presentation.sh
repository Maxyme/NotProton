#!/bin/bash
# ==============================================================================
# test-window-presentation.sh
#
# Validates that a game window is actively displaying and presenting frames
# on macOS using WindowServer CoreGraphics metadata and Wine presentation logs.
#
# STRICT CONSTRAINT: Zero screen capture / zero image file generation.
# ==============================================================================

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <AppID>"
    exit 1
fi
APPID="$1"

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}==============================================================================${NC}"
echo -e "${BLUE}${BOLD}  NotProton Window Presentation & Rendering Validator${NC}"
echo -e "${BLUE}${BOLD}  AppID: ${BOLD}$APPID${NC}"
echo -e "${BLUE}${BOLD}==============================================================================${NC}"
echo ""

# 1. Identify Running Wine Game PIDs
wine_helpers='winedevice\.exe|services\.exe|plugplay\.exe|svchost\.exe|rpcss\.exe|explorer\.exe'
GAME_PIDS=$(ps -ww -eo pid,args 2>/dev/null | \
    grep -iE '/(wine|wine64|wine-preloader|wine64-preloader)' | \
    grep -iE '\.exe' | \
    grep -viE "$wine_helpers" | \
    awk '{print $1}' | tr '\n' ',' || true)
GAME_PIDS="${GAME_PIDS%,}"

if [ -n "$GAME_PIDS" ]; then
    echo -e "  [✓] Active Wine Game Process: PID(s) ${BOLD}${GAME_PIDS}${NC}"
else
    echo -e "  [!] No active game process found running right now for Wine."
fi

# 2. Query WindowServer Metadata via CoreGraphics (Swift)
SWIFT_CHECK=$(swift - "$GAME_PIDS" << 'EOF'
import CoreGraphics
import Foundation

let pidArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let targetPids = Set(pidArg.split(separator: ",").compactMap { Int32($0) })

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var bestMatch: [String: Any]? = nil

for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let width = bounds["Width"] as? Double ?? 0.0
    let height = bounds["Height"] as? Double ?? 0.0

    let isMatch = targetPids.contains(pid) || owner.lowercased().contains("wine")
    if isMatch && width > 100 && height > 100 && layer <= 30 {
        // Prioritize onscreen windows and windows with game names
        if onscreen && !name.isEmpty {
            bestMatch = w
            break
        } else if onscreen {
            bestMatch = w
        } else if bestMatch == nil {
            bestMatch = w
        }
    }
}

if let w = bestMatch {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 0.0
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    let width = bounds["Width"] as? Double ?? 0.0
    let height = bounds["Height"] as? Double ?? 0.0

    print("WINDOW_FOUND=1")
    print("PID=\(pid)")
    print("WID=\(wid)")
    print("NAME=\(name.isEmpty ? "(untitled game window)" : name)")
    print("OWNER=\(owner)")
    print("ONSCREEN=\(onscreen)")
    print("ALPHA=\(alpha)")
    print("WIDTH=\(Int(width))")
    print("HEIGHT=\(Int(height))")
} else {
    print("WINDOW_FOUND=0")
}
EOF
)

WINDOW_FOUND=$(echo "$SWIFT_CHECK" | grep "WINDOW_FOUND=" | cut -d= -f2 || echo 0)
ONSCREEN="false"
if [ "$WINDOW_FOUND" = "1" ]; then
    ONSCREEN=$(echo "$SWIFT_CHECK" | grep "ONSCREEN=" | cut -d= -f2)
    ALPHA=$(echo "$SWIFT_CHECK" | grep "ALPHA=" | cut -d= -f2)
    WIDTH=$(echo "$SWIFT_CHECK" | grep "WIDTH=" | cut -d= -f2)
    HEIGHT=$(echo "$SWIFT_CHECK" | grep "HEIGHT=" | cut -d= -f2)
    NAME=$(echo "$SWIFT_CHECK" | grep "NAME=" | cut -d= -f2)
    OWNER=$(echo "$SWIFT_CHECK" | grep "OWNER=" | cut -d= -f2)
    PID=$(echo "$SWIFT_CHECK" | grep "PID=" | cut -d= -f2)
    WID=$(echo "$SWIFT_CHECK" | grep "WID=" | cut -d= -f2)

    echo -e "  [✓] Game Window Found: ${BOLD}$NAME${NC} (Window ID: $WID, Owner: $OWNER, PID: $PID)"
    echo -e "      Geometry: ${BOLD}${WIDTH}x${HEIGHT}${NC}"
    
    if [ "$ONSCREEN" = "true" ]; then
        echo -e "  [✓] WindowServer Compositor: ${GREEN}${BOLD}ONSCREEN (Composited to Display)${NC}"
    else
        echo -e "  [✗] WindowServer Compositor: ${RED}${BOLD}NOT ONSCREEN (Occluded or Hidden)${NC}"
    fi

    if [ "$ALPHA" = "1.0" ] || [ "$ALPHA" = "1" ]; then
        echo -e "  [✓] Window Opacity: ${GREEN}1.0 (Fully Opaque)${NC}"
    else
        echo -e "  [!] Window Opacity: ${YELLOW}$ALPHA${NC}"
    fi
else
    echo -e "  [!] No active game window detected in WindowServer."
fi

# 3. Check Wine Presentation Pipeline & Swapchain Logs
LOG_RUN="$HOME/Library/Application Support/Steam/steamapps/compatdata/$APPID/notproton-run.log"
LOG_WINE="$HOME/Library/Application Support/notproton/launchers/$APPID/notproton-wine.log"

echo ""
echo -e "${BLUE}${BOLD}==>${NC} Inspecting Wine Swapchain & Frame Presentation Pipeline..."

FAULT_COUNT=0
if [ -f "$LOG_RUN" ]; then
    FAULT_COUNT=$(grep -c "wglSwapBuffers returned 0xc0000005" "$LOG_RUN" 2>/dev/null || true)
fi
if [ -f "$LOG_WINE" ]; then
    FAULT_COUNT=$((FAULT_COUNT + $(grep -c "wglSwapBuffers returned 0xc0000005" "$LOG_WINE" 2>/dev/null || true)))
fi

if [ "$FAULT_COUNT" -eq 0 ]; then
    echo -e "  [✓] Swapchain Faults: ${GREEN}${BOLD}0 (No buffer swap crashes)${NC}"
else
    echo -e "  [✗] Swapchain Faults: ${RED}${BOLD}$FAULT_COUNT (wglSwapBuffers crashed)${NC}"
fi

# Check for successful FPS / Present markers if present in log
FPS_LINES=$(grep -E 'wglSwapBuffers @ approx|wined3d_cs_exec_present @ approx' "$LOG_RUN" 2>/dev/null | tail -2 || true)
if [ -n "$FPS_LINES" ]; then
    echo -e "  [✓] Swapchain Presentation Rate:"
    while IFS= read -r line; do
        fps=$(echo "$line" | sed -nE 's/.*approx ([0-9.]+fps).*/\1/p')
        echo -e "      - ${GREEN}${BOLD}$fps${NC}"
    done <<< "$FPS_LINES"
fi

echo ""
echo -e "${BLUE}${BOLD}==============================================================================${NC}"
if [ "$WINDOW_FOUND" = "1" ] && [ "$ONSCREEN" = "true" ] && [ "$FAULT_COUNT" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  RESULT: PASS - Game window is active, onscreen, and presenting cleanly.${NC}"
elif [ "$FAULT_COUNT" -gt 0 ]; then
    echo -e "${RED}${BOLD}  RESULT: FAIL - Game presentation is faulting (wglSwapBuffers crash).${NC}"
else
    echo -e "${YELLOW}${BOLD}  RESULT: Game is not currently running. Launch via Steam or ./scripts/launch-game.sh $APPID${NC}"
fi
echo -e "${BLUE}${BOLD}==============================================================================${NC}"
