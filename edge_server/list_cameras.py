import time
import cv2

names = []
try:
    import comtypes
    comtypes.CoInitialize()
    from pygrabber.dshow_graph import FilterGraph
    names = list(FilterGraph().get_input_devices())
except Exception as e:
    print("Could not read camera names:", e)
    print("Run:  python -m pip install pygrabber")

print()
print("Cameras Windows knows about:")
for i, n in enumerate(names):
    print(f"  [{i}] {n}")
if not names:
    print("  (no names available)")
print()
print("Now each camera is shown for 3 seconds. Note which picture goes with which number.")
print()

for i in range(6):
    cap = cv2.VideoCapture(i, cv2.CAP_DSHOW)
    if not cap.isOpened():
        cap.release()
        continue
    label = names[i] if i < len(names) else "name unknown"
    shown = False
    t0 = time.time()
    while time.time() - t0 < 3:
        ok, frame = cap.read()
        if ok and frame is not None:
            shown = True
            cv2.putText(frame, f"[{i}] {label}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
            cv2.imshow("Camera test", frame)
            cv2.waitKey(30)
    cap.release()
    cv2.destroyAllWindows()
    print(f"[{i}] {label}: " + ("picture OK" if shown else "opened but no picture"))

print("Done.")