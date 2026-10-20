from PIL import Image
import numpy as np

img = Image.open('/Users/zhaozipeng/DevEcoStudioProjects/okvideo-hap/screenshot_ref.jpg')
arr = np.array(img)
h, w = arr.shape[:2]
print(f"Image: {w}x{h}")

# Sample background color
bg = arr[50, 50]
print(f"Background (top-left): RGB({bg[0]}, {bg[1]}, {bg[2]})")

# Average brightness
avg = np.mean(arr)
print(f"Average brightness: {avg:.1f} => {'Dark' if avg < 128 else 'Light'} theme")

# Analyze horizontal bands - find rows with significant color variation (UI elements)
print("\n=== Row analysis (every 40px) ===")
for y in range(0, h, 40):
    row = arr[y]
    # Find color transitions
    transitions = []
    for x in range(1, w, 5):
        diff = sum(abs(int(a)-int(b)) for a,b in zip(row[x][:3], row[x-5][:3]))
        if diff > 40:
            transitions.append(x)
    if transitions:
        # Sample the dominant colors in this row
        samples = [tuple(arr[y, x][:3]) for x in range(0, w, 100)]
        print(f"  y={y:4d}: {len(transitions)} transitions, colors={samples[:5]}")

# Check for card/panel regions (areas with different background color)
print("\n=== Background color regions ===")
prev_bg = None
for y in range(0, h, 20):
    # Sample background at left margin
    pixel = tuple(arr[y, 30][:3])
    if prev_bg is not None:
        diff = sum(abs(a-b) for a,b in zip(pixel, prev_bg))
        if diff > 30:
            print(f"  y={y:4d}: bg changed from {prev_bg} to {pixel}")
    prev_bg = pixel
