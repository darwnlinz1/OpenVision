# BÁO CÁO TOÀN DIỆN AUDIT HỆ THỐNG (PROJECT AUDIT)
## RAY-BAN META GEN 2 × GOOGLE GEMINI MATH SOLVER

*Mã tài liệu:* `PROJECT_AUDIT.md`  
*Ngày thực hiện:* 07/11/2026  
*Trạng thái kiểm tra:* Hoàn tất 100%  
*Đối tượng audit:* `c:\Users\Minh\Downloads\visor for my phone`, `PROJECT_MEMORY.md`, `macedonga/visor`, `darwnlinz1/OpenVision`, `rayl15/OpenVision`, Meta Wearables DAT SDK 0.9.0.

---

## 1. TỔNG QUAN HIỆN TRẠNG & LỊCH SỬ DỰ ÁN

Dự án có mục tiêu duy nhất: **Biến kính thông minh Ray-Ban Meta Gen 2 thành một thiết bị hỗ trợ giải bài tập chuyên nghiệp bằng Google Gemini API**, sử dụng camera tích hợp trên kính để chụp ảnh bài tập và trả lời qua loa kính kết hợp hiển thị chi tiết trên màn hình iPhone 15 Pro.

Qua quá trình audit thực tế mã nguồn và bộ nhớ dự án (`PROJECT_MEMORY.md`), dự án đã trải qua hai giai đoạn phát triển phân mảnh:

1. **Giai đoạn 1 (Android / Visor):**
   - Sử dụng mã nguồn Android Kotlin từ repository `macedonga/visor` (AGPL-3.0).
   - Giao tiếp với kính Ray-Ban Meta qua giao thức Bluetooth DataX đảo ngược (Reverse-Engineered): Service 15 (Control/Thrift NetEvents), Service 33 (MobileConfig), Service 53 (Airship Media Stream).
   - Xây dựng một local bridge server `antigravity_bridge.py` trên PC để làm proxy trung gian OpenAI-compatible tới Google Gemini API.
   - **Hạn chế cốt tử:** Không thể triển khai trực tiếp trên iPhone của người dùng (iPhone 15 Pro iOS 18/26).

2. **Giai đoạn 2 (iOS / OpenVision):**
   - Fork repository `rayl15/OpenVision` sang `darwnlinz1/OpenVision`.
   - Sử dụng Meta Wearables Device Access Toolkit chính thức (`MWDATCore.framework` và `MWDATCamera.framework` v0.9.0).
   - Đã xây dựng thành công quy trình build GitHub Actions trên runner `macos-26` với XcodeGen, đóng gói thành công unsigned IPA `OpenVision.ipa` (kích thước 49,593,883 bytes ~ 49.6 MB).
   - **Hạn chế cốt tử:** Bị nhồi nhét quá nhiều tính năng nặng nề (MLX-LM, mô hình Gemma 4/SmolVLM chạy on-device, Kokoro TTS 82M), sử dụng cơ chế truyền stream video WebSocket liên tục vào `gemini-2.0-flash-exp` (model này hiện đã bị Google khai tử - HTTP 404), đồng thời nén ảnh xuống mức 512px (gây mờ và mất hết công thức toán học).

---

## 2. LÀM RÕ SỰ KHÁC NHAU: VISOR VS OPENVIEW VS OPENVISION

Nghiên cứu và audit đối chiếu cho thấy:
- **Visor (`macedonga/visor`):** Ứng dụng Android mã nguồn mở (AGPL-3.0). Hoàn toàn độc lập với Meta View app, tự giao tiếp trực tiếp với Bluetooth LE DataX của kính. KHÔNG có phiên bản iOS.
- **OpenView:** KHÔNG TỒN TẠI repository hay framework chính thức nào mang tên "OpenView". Đây là sự nhầm lẫn thuật ngữ giữa **Meta View** (ứng dụng quản lý chính thức của Meta trên App Store) và **OpenVision**.
- **OpenVision (`rayl15/OpenVision`, fork `darwnlinz1/OpenVision`):** Ứng dụng iOS native viết bằng Swift/SwiftUI. Được thiết kế để chạy trên iOS 18+ và kết nối với Ray-Ban Meta Gen 1/Gen 2 thông qua Meta Wearables Device Access Toolkit (DAT) SDK chính thức của Meta.

---

## 3. AUDIT CHI TIẾT SOURCE CODE CŨ (VISOR - ANDROID)

### 3.1 Các thành phần đã triển khai
1. **Bluetooth DataX Protocol:**
   - **Service 15 (`Mux Channel 0 / m0`):** Truyền nhận Thrift NetEvents. Visor lắng nghe `EV_FULFILLMENT_REQUEST` (Event 56) và gửi `EV_REMOTE_INTERACTION_RESPONSE` (Event 57) hoặc `EV_CUSTOM_SPEECH_RESPONSE` (Event 392).
   - **Service 33 (`MobileConfig`):** Can thiệp vào watchdog firmware của kính: ghi đè `assistant_on_sn.default_processing_timeout_s = 300L` và `default_responding_timeout_s = 300L` để ngăn kính tự ngắt sau 20s.
   - **Service 53 (`Airship Media Stream`):** Nhận ảnh chụp JPEG full-res (3024x4032, 1-2 MB).
2. **Turn State Machine & Turn Fuser:**
   - `TurnFuser` ghép ảnh chụp trong 60 giây gần nhất với prompt người dùng.
   - Cơ chế `markPhotoConsumed` đảm bảo mỗi ảnh chỉ dùng đúng 1 lần, loại bỏ hoàn toàn thumbnail 240x320.
3. **Bridge Server (`antigravity_bridge.py`):**
   - FastAPI server trên Windows host, cổng 8080.
   - Hỗ trợ API Key Pool xoay vòng qua danh sách working keys.
   - Định dạng kênh đôi (Dual-Channel Formatter):
     - `SPOKEN:` Tóm tắt kết quả bài tập bằng văn bản thuần, không chứa LaTeX, độ dài < 300 ký tự để đọc qua loa kính.
     - `DISPLAY:` Toàn bộ lời giải chi tiết, công thức Markdown/LaTeX để hiển thị trên màn hình điện thoại.

### 3.2 Nguyên nhân cốt lõi vì sao Bluetooth SPP và Wi-Fi Direct P2P của Android không thể mang sang iOS

1. **Rào cản Bluetooth SPP / RFCOMM (Classic Bluetooth):**
   - **Cơ chế trên Android:** Android cung cấp API cấp thấp `BluetoothSocket` với phương thức `createRfcommSocketToServiceRecord(UUID)`. Visor có thể mở trực tiếp các kênh RFCOMM thô tới các UUID dịch vụ nội bộ của kính (Service 15 `m0` cho Thrift NetEvents, Service 33 cho MobileConfig, Service 53 cho Airship) mà không cần sự can thiệp hay chứng nhận từ nhà sản xuất phần cứng.
   - **Rào cản bất khả thi trên iOS:** Framework `CoreBluetooth` trên iOS chỉ hỗ trợ chuẩn Bluetooth Low Energy (BLE GATT: `CBPeripheral`, `CBService`, `CBCharacteristic`). iOS khoá hoàn toàn quyền truy cập Classic Bluetooth (BR/EDR) và RFCOMM/SPP sau bức tường **MFi (Made for iPhone)**. Để mở một kênh truyền thông tin nối tiếp (Serial Port / RFCOMM) trên iOS, thiết bị bắt buộc phải tích hợp chip bảo mật Apple MFi Coprocessor và ứng dụng phải khai báo chuỗi giao thức ExternalAccessory (`EAAccessoryManager`, ví dụ `com.meta.wearable...`). Ứng dụng bên thứ ba thông thường không thể tự mở kết nối RFCOMM tới Ray-Ban Meta mà không có MFi token hợp lệ từ Meta.

2. **Rào cản Wi-Fi Direct P2P (Peer-to-Peer):**
   - **Cơ chế trên Android:** Visor sử dụng `android.net.wifi.p2p.WifiP2pManager` để đàm phán nhóm P2P, kết nối ngầm vào Soft-AP của kính và kéo dữ liệu media luồng ảnh phân giải cao (Service 53) mà không cần ngắt mạng 4G/5G của điện thoại.
   - **Rào cản bất khả thi trên iOS:** Apple nghiêm cấm các ứng dụng iOS tự ý quản lý hoặc cấu hình Wi-Fi P2P. iOS không cung cấp API tương đương với `WifiP2pManager`. Cách duy nhất để ứng dụng iOS kết nối vào Wi-Fi Soft-AP là dùng `NEHotspotConfiguration`, nhưng API này luôn hiển thị hộp thoại xác nhận phiền toái cho người dùng mỗi lần kết nối và làm gián đoạn toàn bộ kết nối Internet di động (khiến việc gọi Gemini API bị tê liệt).

3. **Giải pháp bắt buộc của hệ sinh thái iOS:**
   - Để khắc phục các hạn chế trên, Meta đã phát triển bộ công cụ chính thức **Meta Wearables Device Access Toolkit (DAT)** (`MWDATCore.framework` và `MWDATCamera.framework`).
   - SDK này ủy quyền việc bắt tay MFi và Wi-Fi sang ứng dụng đồng hành **Meta View** (đã được Apple phê duyệt MFi), sau đó truyền luồng điều khiển và dữ liệu ảnh sang OpenVision thông qua App IPC và custom URL Scheme (`openvision://`).

### 3.3 Trích xuất các tinh hoa thuật toán cần giữ lại từ Visor
Dù nền tảng kết nối phần cứng khác nhau, ba tinh hoa thuật toán cốt lõi từ Visor bắt buộc phải được kế thừa trọn vẹn sang ứng dụng iOS mới:

1. **Vòng đời Single-Turn Photo & Thuật toán `markPhotoConsumed`:**
   - Trong quá trình chụp ảnh POV, kính thường tạo ra ảnh thumbnail phụ (240x320) trước khi truyền ảnh chính, hoặc người dùng chụp nhiều lần trong cùng một phiên.
   - Cơ chế `markPhotoConsumed` của Visor gắn nhãn thời gian và trạng thái cho từng bức ảnh. Ngay khi một bức ảnh được nạp vào luồng xử lý AI, nó lập tức được đánh dấu `consumed = true` và bị loại khỏi hàng đợi, ngăn chặn tuyệt đối tình trạng giải lại ảnh cũ hoặc gửi nhầm ảnh thumbnail vỡ nét lên Gemini API.
2. **Bộ đếm thời gian & Chiến lược đối phó Watchdog 20s của kính:**
   - Firmware của kính Ray-Ban Meta tích hợp bộ giám sát cứng (Watchdog Timer): Nếu một phiên tương tác âm thanh hoặc camera kéo dài quá 20 giây mà không nhận được tín hiệu phản hồi từ điện thoại, kính sẽ tự động ngắt kết nối và phát tiếng "bip" báo lỗi.
   - Visor can thiệp vào MobileConfig Service 33 để tăng timeout lên 300s. Trên iOS, do không thể can thiệp firmware thô, ứng dụng giải quyết triệt để vấn đề này bằng cách:
     - Chuyển sang mô hình chụp ảnh tĩnh theo yêu cầu (On-Demand Single-Turn Capture) thay vì mở stream liên tục.
     - Tối ưu hóa toàn bộ pipeline AI (nén ảnh 2048px, gọi trực tiếp Gemini REST v1beta) để đạt thời gian phản hồi thực tế **2.52s**, bỏ xa ngưỡng giới hạn 20s của Watchdog.
3. **Kiến trúc Kênh đôi Phản hồi (`SPOKEN:` vs `DISPLAY:`):**
   - Trực tiếp giải quyết mâu thuẫn giữa trải nghiệm nghe qua loa kính và trải nghiệm đọc đề giải toán:
     - Kênh `SPOKEN:`: Giới hạn nghiêm ngặt dưới 250 ký tự, lược bỏ hoàn toàn các ký hiệu toán học LaTeX phức tạp (`\int`, `\frac`, `\sqrt`), chỉ đọc đáp số cuối cùng hoặc phương án chọn (A, B, C, D) bằng tiếng Việt tự nhiên qua loa kính.
     - Kênh `DISPLAY:`: Giữ nguyên toàn bộ các bước biến đổi chi tiết, lập luận chặt chẽ và công thức toán học chuẩn LaTeX để hiển thị trực quan trên màn hình iPhone.

## 4. AUDIT CHI TIẾT SOURCE CODE OPENVISION (IOS)

### 4.1 Kiến trúc & Các thành phần tái sử dụng được
1. **Meta Wearables DAT Integration (`OpenVision/Managers/GlassesManager.swift`):**
   - Sử dụng thư viện `MWDATCore` và `MWDATCamera` phiên bản 0.9.0 từ Meta (`https://github.com/facebook/meta-wearables-dat-ios`).
   - Quản lý vòng đời thiết bị: `wearables.registrationStateStream()`, `wearables.startRegistration()`, `wearables.devicesStream()`.
   - Quản lý phiên làm việc: `wearables.createSession(deviceSelector:)`, `session.start()`, `session.addCamera(config:)`.
   - Cơ chế chụp ảnh native từ camera kính: `cam.stream.capturePhoto(format: .jpeg)` và lắng nghe qua `photoDataPublisher`.
2. **Cơ chế âm thanh (`AudioSessionManager.swift`):**
   - Thiết lập `AVAudioSession` với category `.playAndRecord`, mode `.videoChat`/`.voiceChat`, options `[.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]`.
   - Nhờ vậy, bất kỳ âm thanh TTS nào phát từ iPhone đều được truyền trực tiếp vào loa mở (open-ear temple speakers) của kính Ray-Ban Meta.
3. **Quy trình Build Unsigned IPA:**
   - Đã cấu hình hoàn hảo `project.yml` (XcodeGen) và `.github/workflows/build-ipa.yml` chạy trên runner `macos-26` với Xcode 26.6.
   - Script tự động hóa `build_openvision_ipa.py` đã tải và đóng gói thành công `OpenVision.ipa`.

### 4.2 Các lỗi nghiêm trọng và điểm nghẽn trong OpenVision
1. **Nén ảnh quá mức làm hỏng bài tập toán (`Constants.Camera`):**
   - Tại `OpenVision/Config/Constants.swift` (dòng 114-118):
     ```swift
     enum Camera {
         static let maxPhotoDimension: CGFloat = 512
         static let photoJPEGQuality: CGFloat = 0.5
         static let captureTimeout: TimeInterval = 10.0
     }
     ```
   - **Hậu quả:** Ảnh từ camera Ray-Ban Meta bị thu nhỏ về tối đa 512px và nén JPEG 50%. Ở độ phân giải này, các chỉ số trên/dưới (subscript, superscript), dấu tích phân, phân số và chữ viết tay bị vỡ nát hoàn toàn, khiến Gemini đọc sai đề thi.
2. **Model Gemini bị khai tử (HTTP 404):**
   - Tại `OpenVision/Services/GeminiLive/GeminiVisionService.swift` (dòng 179): Hardcoded model `"model": "models/gemini-2.0-flash-exp"`.
   - Tại `OpenVision/Config/Constants.swift` (dòng 27): Hardcoded model `"models/gemini-2.5-flash-native-audio-preview-12-2025"`.
   - **Kết quả kiểm thử thực tế:** Google Generative Language API trả về mã lỗi **HTTP 404 Not Found** ("This model is no longer available").
3. **Cơ chế truyền video WebSocket liên tục (Gemini Live) gây lãng phí và mất ổn định:**
   - OpenVision đẩy video frames 1-2 FPS liên tục qua WebSocket `wss://generativelanguage.googleapis.com/...`.
   - Đối với tác vụ giải bài tập, việc truyền video liên tục gây hao pin kính, ngốn băng thông 4G/5G, tiêu tốn quota token khổng lồ và độ trễ cao. Cần chuyển sang chụp ảnh đơn theo yêu cầu (On-Demand Still Photo Capture).
4. **Giới hạn Output Token quá thấp (`CloudChat.swift`):**
   - Dòng 18 quy định: `maxTokens: Int? = 400`.
   - **Hậu quả:** Các bài toán đại số, giải tích, hình học cần dẫn chứng bước giải dài sẽ bị ngắt cụt câu trả lời giữa chừng.
5. **Dung lượng IPA bị phình to (49.6 MB) do nhồi nhét mô hình on-device:**
   - OpenVision bundle hàng loạt thư viện nặng: `mlx-swift`, `mlx-swift-lm`, `KokoroSwift` (on-device TTS), `MisakiSwift`, `FluidAudio`.
   - Những thành phần này không cần thiết cho mục tiêu giải bài tập, làm tiêu tốn RAM của iPhone và tăng nguy cơ bị iOS kill app khi chạy nền.

---

## 5. DANH SÁCH CHỨC NĂNG CẦN GIỮ NGUYÊN VÀ THÀNH PHẦN CẦN THAY THẾ

| STT | Thành phần / Chức năng | Hiện trạng | Quyết định | Rationale kỹ thuật |
|---|---|---|---|---|
| 1 | **Meta Wearables DAT 0.9.0** | `MWDATCore`, `MWDATCamera` | **GIỮ NGUYÊN** | Giao thức chuẩn xác và duy nhất được Meta hỗ trợ chính thức trên iOS để kết nối Ray-Ban Meta Gen 2. |
| 2 | **Quy trình Build GitHub Actions** | `build-ipa.yml`, `project.yml` | **GIỮ NGUYÊN** | Đã được kiểm chứng build thành công trên `macos-26`, tự động đóng gói IPA không cần Mac nội bộ. |
| 3 | **Cơ chế Audio A2DP/HFP** | `AudioSessionManager.swift` | **GIỮ NGUYÊN** | Tận dụng CoreAudio iOS để đưa âm thanh lời giải trực tiếp lên loa kính Ray-Ban Meta. |
| 4 | **Logic Dual-Channel (SPOKEN vs DISPLAY)** | `antigravity_bridge.py` | **GIỮ & PORT SANG SWIFT** | Đảm bảo trải nghiệm giải bài tập: loa chỉ đọc kết quả ngắn gọn, màn hình hiển thị toàn bộ bài giải LaTeX. |
| 5 | **Độ phân giải nén ảnh (512px)** | `Constants.Camera.maxPhotoDimension` | **THAY THẾ TOÀN BỘ** | Tăng lên 1536–2048px với chất lượng JPEG 85–90% để đảm bảo độ sắc nét của công thức toán. |
| 6 | **Gemini Live WebSocket Engine** | `GeminiVisionService.swift` | **THAY THẾ TOÀN BỘ** | Thay bằng **Gemini HTTPS REST Provider** chuyên dụng, hỗ trợ thinking config và key pooling. |
| 7 | **Các model cũ (gemini-2.0, gemini-2.5)** | Hardcoded trong source | **THAY THẾ TOÀN BỘ** | Thay bằng `gemini-3.5-flash-lite` (Primary, 500 RPD) và `gemini-3.1-flash-lite` (Fallback, 500 RPD). |
| 8 | **Token Clamp (maxTokens: 400)** | `CloudChat.swift` | **THAY THẾ TOÀN BỘ** | Mở rộng lên 4,096 - 8,192 tokens cho phép giải quyết trọn vẹn đề thi khó. |
| 9 | **On-device MLX & Kokoro TTS** | Bundle trong `project.yml` | **LOẠI BỎ** | Giảm kích thước IPA từ 50MB xuống <10MB, tiết kiệm pin và bộ nhớ máy. |


---

## 6. AUDIT ĐẶC BIỆT: NGUYÊN NHÂN GỐC RỄ CỦA LỖI ĐƠ APP, GIẬT VOLUME & NGẮT TTS (07/11/2026)

### 6.1 Bối cảnh
Người dùng báo cáo 4 triệu chứng nghiêm trọng khi chạy ứng dụng trên iPhone 15 Pro kết nối kính Ray-Ban Meta Gen 2:
1. Chạm vào ghi âm/mic làm ứng dụng đứng đơ hoàn toàn (deadlock).
2. Thanh âm lượng hệ thống iOS giật nảy liên tục giữa Call Volume và Media Volume.
3. Kính đọc đáp án được 2-3 giây thì tắt ngúm giữa câu ("point vào textbook...").
4. Gọi agent qua micro kính Ray-Ban hoàn toàn không phản hồi.

### 6.2 Phân tích cơ chế kỹ thuật (Root Cause Analysis)
1. **Bão đệ quy Audio Route (Infinite Re-entrancy Storm)**:
   - Trong `AudioSessionManager.swift:63-73`, sự kiện `.routeConfigurationChange` kích hoạt `setPreferredInput(hfp)` và gọi callback `onRouteChange`.
   - `VoiceAgentViewModel.swift:741` đón callback này và dispatch `configureAudioForGlasses(forceRestart: true)`.
   - `forceRestart: true` cưỡng chế `audioSession.setCategory(...)` và restart `AVAudioEngine`, tạo ra notification `.routeConfigurationChange` tiếp theo.
   - Vòng lặp đệ quy này chạy hàng chục lần mỗi giây trên MainActor. Mỗi lần renegotiate Bluetooth HFP SCO tốn 1-2s của `mediaserverd`, gây Mach IPC Deadlock khóa cứng Main Thread và làm thanh âm lượng giật liên tục giữa hai domain Call Volume (SCO) và Media Volume (Loa ngoài).
2. **Hủy diệt tiến trình TTS (AVSpeechSynthesizer Preemption)**:
   - Khi Gemini trả về đáp án, `AVSpeechSynthesizer.speak()` phát âm thanh. Âm thanh kích hoạt thay đổi cấu hình âm thanh iOS, dẫn đến vòng lặp trên tái kích hoạt `audioSession.setCategory`.
   - Theo cơ chế CoreAudio iOS, việc tái cấu hình `AVAudioSession` khi synthesizer đang hoạt động sẽ lập tức hủy bỏ (cancel) toàn bộ buffer giọng nói đang phát, gây hiện tượng cụt tiếng sau 2-3 giây.
3. **Lệch âm vị tiếng Việt (Locale Phonetic Mismatch)**:
   - Trên thiết bị iOS ngôn ngữ Tiếng Việt, `SFSpeechRecognizer` sử dụng `vi-VN` và phiên âm "Ok Vision" thành `"ô kê vi dơn"`, `"ok vi dơn"`, `"vi dơn"`.
   - Bộ lọc Wake Word cũ chỉ kiểm tra chuỗi tiếng Anh (`"ok vision"`), dẫn đến toàn bộ câu lệnh gọi agent qua kính bị bỏ qua.

### 6.3 Giải pháp đã triển khai (Triệt để & Đã xác minh)
1. **Lọc sự kiện & Debounce `AudioSessionManager`**: Bỏ `setPreferredInput` khỏi `routeConfigurationChange`, áp dụng debounce tối thiểu 1.5s.
2. **Tắt `forceRestart`**: Đổi cờ gọi route change thành `forceRestart: false`, tuyệt đối không reset Audio Engine khi `AVSpeechSynthesizer` đang nói.
3. **Bổ sung từ khóa Tiếng Việt**: Thêm đầy đủ biến thể âm vị tiếng Việt vào `VoiceCommandService`.
4. **Phục hồi cơ chế Chụp trước - Hỏi sau**: Hoàn thiện nút chụp nhanh trên TopBar với chỉ báo xanh lá (60s TTL), liên kết trực tiếp với Gemini 3.5 Flash Lite REST solver.


---

## 7. ĐIỀU TRA CHUYÊN SÂU & GIẢI QUYẾT TRIỆT ĐỂ 4 LỖI CỐT TỬ (V5 MASTER FIX)

Sau quá trình kiểm thử thực tế của người dùng, hệ thống đã phát hiện và xử lý tận gốc 4 lỗi nghiêm trọng:

### 7.1 Lỗi 1: Đứng ứng dụng / Treo đơ hoàn toàn khi đụng đến Ghi âm (`SessionRecorder`)
* **Hiện tượng**: Bấm ghi âm hoặc chạy tính năng ghi âm là ứng dụng đứng hình 100%.
* **Nguyên nhân gốc rễ**: 
  - `SessionRecorder.swift` tự khởi tạo một instance `audioEngine = AVAudioEngine()` riêng biệt và gọi `inputNode.installTap(onBus: 0)` và `audioEngine.start()`.
  - Đồng thời, `VoiceCommandService.swift` cũng đang chạy một `AVAudioEngine()` riêng để lắng nghe wake-word trên Bus 0 của microphone phần cứng.
  - Trong CoreAudio của iOS, hai instance `AVAudioEngine` độc lập không thể cùng lúc cài đặt phần cứng Tap trên Bus 0 của inputNode. Thao tác này kích hoạt ngoại lệ `EINAudioEngineInstallTapOnNode` và khóa chết Mach IPC giữa ứng dụng và `mediaserverd`.
* **Giải pháp triệt để**:
  - Loại bỏ hoàn toàn việc khởi tạo `AVAudioEngine` thứ hai trong `SessionRecorder`.
  - Chuyển `SessionRecorder` sang chế độ Shared Microphone Tap (`isSharingVoiceCommandTap = true`): `VoiceCommandService` chịu trách nhiệm duy nhất quản lý Audio Engine và tự động chuyển tiếp buffer âm thanh sang `SessionRecorder.shared.appendMicAudio(buffer)`.
  - Triệt tiêu 100% tình trạng tranh chấp phần cứng, ghi âm hoạt động mượt mà không còn hiện tượng treo app.

### 7.2 Lỗi 2: Thanh âm lượng nhảy giật liên tục ("Nút âm lượng chỉnh tùm lum")
* **Hiện tượng**: HUD âm lượng của iOS liên tục hiện lên và nhảy loạn xạ giữa Call Volume và Media Volume.
* **Nguyên nhân gốc rễ**: 
  - Sự dao động liên tục giữa chế độ Bluetooth HFP (Voice/Telephony SCO) và Media Audio (A2DP).
  - Khi ứng dụng liên tục gọi `configureForPhone()` và `configureForGlasses()`, iOS bị ép đổi giữa hai miền âm lượng độc lập của hệ thống (Call Volume và Media Volume), khiến HUD âm lượng nhảy giật liên tục.
* **Giải pháp triệt để**:
  - Thiết lập cấu hình Audio Session cố định: Category `.playAndRecord`, mode `.default`, options `[.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]`.
  - Thêm phương thức `configureCategoryAllowingBluetooth()` giữ luồng Bluetooth HFP và A2DP luôn mở ổn định, không bao giờ ép `setPreferredInput(nil)` gây xung đột miền âm lượng.

### 7.3 Lỗi 3: Trả lời được 2–3 giây là tắt ngúm giữa chừng (TTS Cutoff)
* **Hiện tượng**: Gemini trả lời được một nửa hoặc 2-3 giây đầu ("Để giải bài toán này...") thì bỗng nhiên tắt ngúm âm thanh.
* **Nguyên nhân gốc rễ (Smoking Gun)**:
  - Loa gọng kính Ray-Ban Meta nằm sát mic thu âm trên gọng kính. Khi loa phát ra câu trả lời của Gemini: *"Để giải bài toán tích phân này..."*, mic thu âm thu lại chính giọng nói TTS này (acoustic echo).
  - Trong `VoiceCommandService.swift`, danh sách `wakeWordVariations` trước đây bị nhét nhầm các từ khóa câu lệnh như `"giải bài này"`, `"bài toán"`.
  - Mic nghe thấy từ `"bài toán"` từ chính loa kính phát ra -> Hệ thống tưởng người dùng vừa gọi Wake Word ngắt lời (Barge-in interrupt) -> Kích hoạt `onWakeWordDetected?()` -> Gọi `ttsService.stop()` -> Giết chết câu trả lời của Gemini ngay giây thứ 2!
* **Giải pháp triệt để**:
  - Tách bạch tuyệt đối: `wakeWordVariations` CHỈ chứa các biến thể wake word chính danh (`"ok vision"`, `"ô kê vi dơn"`, `"vi dơn"`). Các từ khóa câu lệnh (`"bài toán"`, `"giải bài này"`) được chuyển hoàn toàn sang bộ nhận diện lệnh bài tập `photoKeywords`.
  - Thiết lập khiên bảo vệ phát âm: Trong suốt thời gian TTS đang phát âm (`isBargeInPaused = true` hoặc `ttsService.isSpeaking`), hệ thống KHÓA CHẶT toàn bộ cơ chế tự kích hoạt wake-word từ âm thanh môi trường/loa kính. CHỈ cho phép dừng khi người dùng nói rõ ràng từ lệnh dừng dứt khoát (`"stop"`, `"dừng lại"`, `"ok vision stop"`).

### 7.4 Lỗi 4: Mất cơ chế Chụp trước - Hỏi sau ("Point at the textbook")
* **Hiện tượng**: Người dùng hỏi giải bài nhưng Gemini lại trả lời bảo "hướng camera vào sách giáo khoa", do Gemini chỉ nhận được câu hỏi chữ mà không nhận được hình ảnh bài tập.
* **Nguyên nhân gốc rễ**: 
  - Khi người dùng hỏi câu hỏi không chứa chính xác từ khóa "take a photo", app gửi text thô sang Gemini thay vì tự động đính kèm ảnh đã chụp trước hoặc tự động kích hoạt chụp ảnh từ kính.
  - Thời gian sống (TTL) của ảnh chụp trước chỉ có 60 giây và bị đánh dấu `isConsumed = true` ngay lần hỏi đầu tiên, khiến câu hỏi tiếp theo bị mất ảnh.
* **Giải pháp triệt để**:
  - Nâng thời gian sống của ảnh chụp trước (`CapturedPhotoContext`) lên 120 giây (2 phút), cho phép hỏi dồn nhiều câu hỏi trên cùng một trang sách đã chụp.
  - Tự động dung hợp: Khi có ảnh chụp trước còn hiệu lực, BẤT KỲ câu hỏi nào của người dùng đều tự động được đính kèm ảnh gửi sang Gemini 3.5 Flash Lite.
  - Tự động chụp bù: Nếu chưa có ảnh trong bộ nhớ đệm mà người dùng nói các từ khóa giải toán POV (`"giải bài này"`, `"tính câu này"`, `"đáp án"`, `"bài toán"`, `"phương trình"`, v.v.), ứng dụng tự động chụp ảnh ngay từ camera kính Ray-Ban Meta (`captureAndSendPhoto`) rồi mới gửi kèm sang Gemini. Tuyệt đối không để xảy ra tình trạng gửi câu hỏi không kèm ảnh khiến Gemini trả lời "point at the textbook".

### 7.5 Lỗi 5: Gọi agent qua kính không ăn, nói vào điện thoại mới nghe
* **Hiện tượng**: Mic kính Ray-Ban không nhận lệnh, phải dí sát điện thoại nói mới nhận.
* **Nguyên nhân gốc rễ**: 
  - `AudioSessionManager` khi khởi động kiểm tra `availableInputs` ngay lập tức tại thời điểm 0ms. Lúc này Bluetooth HFP chưa kịp đàm phán SCO xong, dẫn đến app tưởng không có kính và fallback về `configureForPhone()`, khóa chặt microphone vào mic iPhone (`setPreferredInput(nil)`).
  - Bộ đệm âm thanh trong callback render thời gian thực bị lọc bỏ tùy tiện bởi `isSilentOrZeroBuffer`, làm bỏ đói bộ nhận diện giọng nói `SFSpeechRecognizer`.
* **Giải pháp triệt để**:
  - Cải tiến `findBluetoothHFPInput()` quét toàn diện mọi cổng `bluetoothHFP` và các thiết bị Ray-Ban Meta/Stories.
  - Giữ category Bluetooth luôn mở với `configureCategoryAllowingBluetooth()`, khi kính kết nối thành công thì iOS tự động gắn kết mic gọng kính mà không bị lock vào mic điện thoại.
  - Loại bỏ hoàn toàn việc drop buffer trong render thread, đảm bảo luồng PCM truyền liên tục 100% vào `recognitionRequest`.
