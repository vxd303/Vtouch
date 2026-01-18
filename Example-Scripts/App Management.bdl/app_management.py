from zxtouch.client import zxtouch


def main():
    device = zxtouch("127.0.0.1")

    # Replace with a bundle identifier installed on your device.
    target_bundle = "com.apple.springboard"

    # All app management calls return (success, value_or_error).
    ok, front_app = device.front_most_app_id()
    print("Frontmost app:", front_app if ok else f"error: {front_app}")

    ok, orientation = device.front_most_orientation()
    print("Frontmost orientation:", orientation if ok else f"error: {orientation}")

    ok, state = device.app_state(target_bundle)
    if ok:
        # app_state returns:
        # 0 -> not running / not found
        # 1 -> running (fallback for older APIs)
        # other integer -> SBApplication processState value
        print("App state:", state)
    else:
        print("App state error:", state)

    ok, info = device.app_info(target_bundle)
    print("App info:", info if ok else f"error: {info}")

    # Example kill (avoid killing SpringBoard in practice).
    # device.app_kill(target_bundle)

    device.disconnect()


if __name__ == "__main__":
    main()
