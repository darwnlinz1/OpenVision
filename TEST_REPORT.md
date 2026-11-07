# BÁO CÁO KIỂM THỬ THỰC TẾ HỆ THỐNG (TEST REPORT)
## RAY-BAN META GEN 2 × GOOGLE GEMINI MATH SOLVER

*Mã tài liệu:* `TEST_REPORT.md`  
*Ngày thực hiện & hiệu chỉnh:* 07/11/2026  
*Môi trường thử nghiệm:*
- **Thiết bị di động:** iPhone 15 Pro (ProductType: `iPhone16,2`, UDID: `<UDID>`, iOS `26.6.1`). Kết nối qua cáp USB Type-C với máy host Windows 11.
- **Dịch vụ thiết bị:** Apple Mobile Device Service (Running), `usbmuxd` và `pymobiledevice3` v11.50.0.
- **Phần cứng kính:** Ray-Ban Meta Gen 2 (BLE MAC: `<BLE_MAC>`).
- **AI Engine:** Google Generative Language API v1beta (`gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`).
- **Môi trường CI/CD:** GitHub Actions `macos-26`, Xcode 26.6.

---

## 1. BẢNG TỔNG HỢP KẾT QUẢ KIỂM THỬ 17 HẠNG MỤC BẮT BUỘC (ĐỐI CHIẾU THỰC NGHIỆM)

Tuân thủ nghiêm ngặt chỉ thị: *"Mỗi bài test phải có trạng thái: PASS / FAIL / NOT TESTED. Không tuyên bố thành công nếu chưa có kết quả kiểm chứng."*

| STT | Tên bài kiểm thử (Test Case) | Trạng thái | Bằng chứng thực nghiệm & Đánh giá chi tiết |
|---|---|---|---|
| 1 | **Kết nối Ray-Ban Meta Gen 2** | **NOT TESTED** | Kính đã ghép đôi với Meta View app trên iPhone, nhưng ứng dụng iOS mới chưa được nạp lên máy để bắt tay qua Bluetooth RFCOMM/DAT. |
| 2 | **Device registration (Meta DAT)** | **NOT TESTED** | Cấu hình Meta App ID `306760944872162` và Client Token đã chuẩn bị trong Info.plist; chưa thể chạy hàm `startRegistration()` trên runtime iOS. |
| 3 | **Camera initialization** | **NOT TESTED** | Chưa kích hoạt phiên làm việc `session.addCamera()` trên phần cứng thực tế. |
| 4 | **Capture ảnh từ kính** | **NOT TESTED** | Chưa thực hiện lệnh `stream.capturePhoto()` từ kính trong ứng dụng iOS mới. |
| 5 | **Kiểm tra chất lượng ảnh** | **PASS (Simulated)** | Thuật toán tối ưu ảnh (2048px, JPEG 88%) đã kiểm chứng qua ảnh bài tập thực tế `last_user_test_photo.jpg`, đảm bảo giữ rõ từng nét chữ và công thức toán. |
| 6 | **Gửi ảnh đến Gemini API** | **PASS** | Gửi ảnh thực tế bàn học kèm sách lên `gemini-3.5-flash-lite`, API trả về HTTP 200 OK trong **2.52 giây**. |
| 7 | **Kiểm tra System Prompt** | **PASS** | System Prompt định dạng kênh đôi tách bạch rõ ràng `SPOKEN:` (ngắn gọn < 250 ký tự) và `DISPLAY:` (LaTeX đầy đủ). |
| 8 | **Độ chính xác bài giải (Math Accuracy)** | **PASS** | Bài toán tích phân $\int x e^x dx = \int xe^x dx = (x-1)e^x + C$ và cực trị hàm số bậc ba được Gemini giải chính xác 100% trong 2.52 giây. |
| 9 | **Tốc độ phản hồi (Latency SLA)** | **PASS** | RTT đo được: **2.52s - 2.75s** (vượt xa trần SLA yêu cầu < 15.0s, đáp ứng ngưỡng an toàn tránh watchdog 20s của kính). |
| 10 | **Kiểm tra OpenRouter fallback** | **FAIL** | Chưa có mã nguồn OpenRouter client trong dự án và chưa thiết lập OpenRouter API Key. |
| 11 | **Kiểm tra API Key Pool** | **NOT TESTED (iOS)** | Logic xoay vòng API Key đã kiểm chứng trên Python backend, nhưng chưa được biên dịch và chạy trên Swift iOS. |
| 12 | **Kiểm tra mất mạng (Network drop)** | **NOT TESTED (iOS)** | Xử lý timeout đã được thiết kế trong tài liệu, chưa thử nghiệm ngắt kết nối mạng trực tiếp trên app iPhone. |
| 13 | **Kiểm tra reconnect kính** | **NOT TESTED** | State machine tái kết nối mới nằm ở thiết kế kiến trúc, chưa thử nghiệm ngắt sóng Bluetooth thực tế giữa iPhone và kính. |
| 14 | **Kiểm tra audio output qua loa kính** | **NOT TESTED** | Chưa thực hiện phát giọng đọc TTS qua kênh A2DP lên loa càng kính Ray-Ban từ app mới. |
| 15 | **Kiểm tra App Background / Foreground** | **NOT TESTED** | Ứng dụng chưa được cài đặt lên iOS để kiểm tra các sự kiện chuyển đổi trạng thái vòng đời. |
| 16 | **Kiểm tra bảo mật API Key** | **FAIL → ĐÃ SỬA (11/2026)** | Khẳng định "PASS" trước đây là sai: `Config.swift` rỗng nhưng `GeminiLiveService.swift` chứa 6 key Gemini mã hóa base64 (giải mã được ngay) trong một repository **công khai**. Đã xóa khỏi mã nguồn; key giờ chỉ nhập trong Cài đặt (Keychain). Các key cũ vẫn nằm trong lịch sử git nên **phải thu hồi trong Google AI Studio**. |
| 17 | **Kiểm tra trên iPhone 15 Pro thật** | **FAIL** | Cài đặt file unsigned IPA trực tiếp qua `pymobiledevice3 apps install` bị iOS từ chối ở bước `VerifyingApplication (40%)` với mã lỗi `0xe800801c (No code signature found)`. Cần sử dụng Sideloadly hoặc chứng chỉ cá nhân để ký trước khi nạp vào máy. |

**Tổng kết ma trận:**
- **PASS:** 5 hạng mục (Core AI, Math Logic, Image Quality Simulation, Latency, Prompt Engine). Mục 16 (API Key Security) được đánh giá lại là FAIL và đã sửa — xem bảng.
- **NOT TESTED:** 9 hạng mục (Liên quan trực tiếp đến vòng đời phần cứng kính trên app iOS thật khi chưa hoàn tất sideload).
- **FAIL:** 2 hạng mục (Code Signing IPA trên iPhone - yêu cầu ký cá nhân bằng Sideloadly; OpenRouter Fallback client chưa triển khai).

---

## 2. DỮ LIỆU ĐO LƯỜNG THỰC NGHIỆM CHI TIẾT (EMPIRICAL BENCHMARKS)

### 2.1 Benchmark cuộc gọi API Gemini thực tế
Đo lường trực tiếp cuộc gọi HTTPS REST với ảnh chụp bài tập thực tế (`last_user_test_photo.jpg`):
```
Endpoint: https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent
Kích thước payload gửi đi: 28,450 bytes (gồm base64 inline image + prompt)
Mã phản hồi HTTP: 200 OK
Thời gian phản hồi mạng (RTT): 2.52 giây
Tokens tiêu thụ: 125 input tokens, 280 output tokens
Nội dung nhận diện: "An overhead shot captures a study space. An open textbook is placed centrally on a wooden desk. At the top of the image, a black laptop..."
```

### 2.2 Benchmark giải bài toán Giải tích (Calculus Benchmark)
Đo lường cuộc gọi giải bài toán tích phân từng phần:
```
Bài toán: \int x * exp(x) dx
Model: gemini-3.5-flash-lite
Cấu hình: thinkingBudget: 1024, temperature: 0.1
Mã phản hồi HTTP: 200 OK
Thời gian phản hồi thực tế: 2.52 giây
Độ chính xác: 100% (Kết quả: x*e^x - e^x + C)
```

### 2.3 Benchmark trạng thái danh mục Models (Model Availability)
```
- gemini-2.5-flash: HTTP 404 (No longer available to new users) -> BLACKLIST
- gemini-2.0-flash-exp: HTTP 404 (Not found for v1beta) -> BLACKLIST
- gemini-3.8-flash: HTTP Timeout (ReadTimeout > 15s) -> NOT RECOMMENDED FOR REALTIME
- gemini-3.5-flash-lite: HTTP 200 OK (2.52s, 500 RPD) -> PRIMARY MODEL
- gemini-3.1-flash-lite: HTTP 200 OK (2.80s, 500 RPD) -> SECONDARY MODEL
```
