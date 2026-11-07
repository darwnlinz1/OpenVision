# HƯỚNG DẪN BUILD VÀ CÀI ĐẶT ỨNG DỤNG IOS (BUILD & DEPLOYMENT INSTRUCTIONS)
## RAY-BAN META GEN 2 × GOOGLE GEMINI MATH SOLVER

*Mã tài liệu:* `BUILD_INSTRUCTIONS.md`  
*Mục tiêu:* Hướng dẫn từng bước từ việc kích hoạt quy trình CI/CD build Unsigned IPA trên đám mây GitHub Actions đến việc cài đặt trực tiếp lên iPhone 15 Pro kết nối qua USB trên Windows 11.

---

## 1. YÊU CẦU MÔI TRƯỜNG & PHẦN CỨNG

1. **Máy tính Host (Development Machine):**
   - Hệ điều hành: Windows 11 64-bit.
   - Python: Phiên bản 3.10 trở lên (đã cài đặt sẵn thư viện `pymobiledevice3`, `httpx`).
   - Cổng kết nối: Cáp USB Type-C cắm trực tiếp từ iPhone 15 Pro vào cổng USB 3.0/Thunderbolt trên PC.
   - Apple Mobile Device Service (AMDS) và dịch vụ `usbmuxd` đang chạy.
2. **Thiết bị Di động Đích (Target iPhone):**
   - Thiết bị: iPhone 15 Pro (Mã nhận diện phần cứng: `iPhone16,2`).
   - Mã UDID: `00008130-001E5CA43EE8001C`.
   - Phiên bản hệ điều hành: iOS 18.x / 26.6.1.
   - Chế độ Developer Mode: Đã bật trong **Cài đặt -> Quyền riêng tư & Bảo mật -> Chế độ nhà phát triển (Developer Mode)**.
3. **Kính Thông minh (Smart Glasses):**
   - Model: Ray-Ban Meta Gen 2 (BLE MAC: `80:AA:1C:F9:87:2E`).
   - Ứng dụng đồng hành Meta View đã cài đặt trên iPhone, tài khoản Meta Developer đã bật Developer Mode.
   - Meta App ID: `306760944872162`.
   - Meta Client Token: `AR|306760944872162|a919421a55a8ea18080ab2f10f57f1be`.
4. **Hạ tầng CI/CD Đám mây (Cloud Builder):**
   - GitHub Repository: `darwnlinz1/OpenVision` (hoặc kho mã nguồn fork của bạn).
   - Runner: `macos-26` (chạy macOS Sequoia với Xcode 26.6 chính thức).

---

## 2. QUY TRÌNH BUILD UNSIGNED IPA TRÊN GITHUB ACTIONS

Quy trình hoàn toàn tự động, không yêu cầu sở hữu máy Mac cục bộ:

### Bước 1: Chuẩn bị cấu hình `Config.xcconfig`
Tạo file `Config.xcconfig` tại thư mục gốc của repository với nội dung:
```xcconfig
DEVELOPMENT_TEAM = 
PRODUCT_BUNDLE_IDENTIFIER = com.minh.openvision
META_APP_ID = 306760944872162
CLIENT_TOKEN = AR|306760944872162|a919421a55a8ea18080ab2f10f57f1be
APP_LINK_URL_SCHEME = openvision
```

### Bước 2: Kích hoạt Workflow Build IPA
Sử dụng script Python tự động hóa đã được kiểm chứng (`build_openvision_ipa.py`):
```powershell
python "c:\Users\Minh\Downloads\visor for my phone\build_openvision_ipa.py"
```

Script sẽ tự động:
1. Xác thực với GitHub API qua Personal Access Token.
2. Kiểm tra và commit các file cấu hình mới nhất (`Config.xcconfig`, `.github/workflows/build-ipa.yml`).
3. Gửi lệnh `workflow_dispatch` để khởi chạy job `Build Unsigned IPA` trên runner `macos-26`.
4. Theo dõi trực tiếp tiến độ biên dịch xcodebuild theo thời gian thực.
5. Tải luồng artifact zip từ GitHub Actions và giải nén thành file `OpenVision.ipa` đặt tại thư mục làm việc.

---

## 3. HƯỚNG DẪN KÝ (SIGNING) VÀ CÀI ĐẶT IPA LÊN IPHONE 15 PRO

Vì file IPA sinh ra từ GitHub Actions là **Unsigned IPA** (chưa ký chứng chỉ cá nhân của bạn), bạn có 2 phương án cài đặt lên iPhone 15 Pro:

### Phương án A: Cài đặt trực tiếp qua `pymobiledevice3` (Dành cho máy đã kích hoạt Developer Mode hoặc chứng chỉ Ad-Hoc)

1. **Kiểm tra kết nối thiết bị qua USB:**
   ```powershell
   python -m pymobiledevice3 usbmux list
   ```
   Xác nhận màn hình terminal hiển thị UDID `00008130-001E5CA43EE8001C`.

2. **Ký nhanh với chứng chỉ cá nhân miễn phí (Ad-Hoc / Apple Free Developer Account):**
   - Bạn có thể sử dụng công cụ mã nguồn mở `zsign` hoặc `AltServer` / `Sideloadly` để ký file `OpenVision.ipa` bằng tài khoản Apple ID miễn phí của mình.
   - Lệnh ký bằng `zsign` (nếu có file chứng chỉ `.p12` và provisioning profile):
     ```powershell
     zsign -k my_cert.p12 -p my_cert_pass -m embedded.mobileprovision -o Signed_Solver.ipa OpenVision.ipa
     ```

3. **Cài đặt file IPA đã ký lên iPhone qua pymobiledevice3:**
   ```powershell
   python -m pymobiledevice3 apps install "c:\Users\Minh\Downloads\visor for my phone\OpenVision.ipa"
   ```

### Phương án B: Cài đặt bằng TrollStore hoặc Sideloadly (Khuyến nghị cho trải nghiệm mượt mà nhất trên Windows)
1. Cài đặt tiện ích **Sideloadly** trên máy tính Windows.
2. Cắm cáp USB nối iPhone 15 Pro với PC. Sideloadly sẽ tự động nhận diện thiết bị `iPhone16,2`.
3. Kéo thả file `c:\Users\Minh\Downloads\visor for my phone\OpenVision.ipa` vào giao diện Sideloadly.
4. Nhập Apple ID cá nhân của bạn và bấm **Start**. Ứng dụng sẽ được ký và cài đặt tự động lên iPhone chỉ trong 30 giây.
5. Trên iPhone: Mở **Cài đặt -> Cài đặt chung -> Quản lý VPN & Thiết bị**, chọn tin cậy chứng chỉ của bạn.

---

## 4. HƯỚNG DẪN CẤU HÌNH & VẬN HÀNH LẦN ĐẦU TRÊN THIẾT BỊ

1. **Khởi động ứng dụng trên iPhone 15 Pro:**
   - Mở ứng dụng `OpenVision` (hoặc `RayBanSolver`).
   - Cấp đầy đủ các quyền khi ứng dụng hỏi: **Bluetooth**, **Camera**, **Microphone**, **Thông báo**.
2. **Bắt tay kết nối với kính Ray-Ban Meta Gen 2:**
   - Đảm bảo kính Ray-Ban Meta đang mở càng và đã kết nối Bluetooth với iPhone.
   - Trong ứng dụng, nhấn **Connect Glasses**.
   - Ứng dụng sẽ kích hoạt luồng đăng ký của Meta Wearables DAT (`wearables.startRegistration()`).
   - Màn hình sẽ chuyển sang ứng dụng Meta View để bạn xác nhận cấp quyền truy cập Camera cho ứng dụng bên thứ ba. Nhấn **Allow / Cho phép**.
   - Sau khi hoàn tất, trạng thái trên màn hình iPhone sẽ chuyển sang màu xanh: **Connected - Ready for Solving**.
3. **Cấu hình Google Gemini API Key:**
   - Mở tab **Settings** trong ứng dụng.
   - Nhập API Key đã kiểm chứng: `YOUR_GEMINI_API_KEY_HERE` (có thể thêm các key dự phòng khác nếu muốn).
   - Chọn Model chính: `gemini-3.5-flash-lite` (500 RPD).
   - Chọn Model phụ: `gemini-3.1-flash-lite` (500 RPD).
4. **Tiến hành giải bài tập thực tế:**
   - Đeo kính Ray-Ban Meta Gen 2 lên mắt, nhìn thẳng vào trang sách hoặc đề thi cần giải.
   - Nhấn nút **Giải Bài** trên màn hình iPhone (hoặc dùng câu lệnh giọng nói nếu cấu hình wake word).
   - Camera trên kính sẽ phát đèn LED nháy sáng báo hiệu đang chụp ảnh.
   - Chỉ trong vòng **2.5 giây**, loa trên gọng kính Ray-Ban sẽ đọc to đáp án ngắn gọn (ví dụ: *"Câu 12 chọn đáp án C, kết quả tích phân là 2"*).
   - Đồng thời, toàn bộ bài giải chi tiết từng bước với đầy đủ công thức LaTeX sẽ xuất hiện ngay lập tức trên màn hình iPhone 15 Pro để bạn theo dõi.
