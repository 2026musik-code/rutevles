from playwright.sync_api import sync_playwright, expect

def verify_dashboard():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(http_credentials={"username": "admin", "password": "admin"})
        page = context.new_page()

        try:
            print("Navigating to dashboard...")
            page.goto("http://localhost:3000/")

            print("Checking title...")
            expect(page).to_have_title("Nautica Admin | VPS Manager")

            print("Checking heading...")
            expect(page.get_by_role("heading", name="Dashboard")).to_be_visible()

            print("Checking stats...")
            expect(page.get_by_text("Total Users")).to_be_visible()
            expect(page.get_by_text("System Status")).to_be_visible()

            print("Taking screenshot...")
            page.screenshot(path="dashboard_verification.png", full_page=True)
            print("Screenshot saved to dashboard_verification.png")

        except Exception as e:
            print(f"Error: {e}")
            page.screenshot(path="error_verification.png")
            raise e
        finally:
            browser.close()

if __name__ == "__main__":
    verify_dashboard()
