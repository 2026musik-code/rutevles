from playwright.sync_api import sync_playwright, expect

def verify_login():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        # New context WITHOUT credentials to force login page
        context = browser.new_context()
        page = context.new_page()

        try:
            print("Navigating to root (should redirect to login)...")
            page.goto("http://localhost:3000/")

            # Check redirect
            expect(page).to_have_url("http://localhost:3000/login.html")
            print("Redirect confirmed.")

            print("Taking screenshot of Login Page...")
            page.screenshot(path="login_page.png")

            # Perform Login
            print("Attempting login...")
            page.fill("#username", "admin")
            page.fill("#password", "admin")
            page.click("button[type=submit]")

            # Check success redirect
            print("Waiting for redirect to dashboard...")
            page.wait_for_url("http://localhost:3000/index.html")
            expect(page).to_have_title("Nautica Admin | VPS Manager")
            print("Login successful.")

            print("Taking screenshot of Dashboard...")
            page.screenshot(path="dashboard_after_login.png")

        except Exception as e:
            print(f"Error: {e}")
            page.screenshot(path="error_login.png")
            raise e
        finally:
            browser.close()

if __name__ == "__main__":
    verify_login()
