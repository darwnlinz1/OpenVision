# Kế hoạch kiểm thử End-to-End (theo MASTER_HANDOVER_BLUEPRINT.md)

> Thiết bị mục tiêu: **iPhone 15 Pro Max, iOS 18+** + **Ray-Ban Meta Gen 2**, backend **Gemini**.
> Workflow chuẩn: bấm nút chụp vật lý trên gọng kính → gọi "Ok Vision" → hỏi **tự do, tiếng Việt hoặc tiếng Anh** → kính đọc câu trả lời, iPhone hiển thị lời giải LaTeX → hỏi tiếp bình thường (về ảnh hoặc chuyện khác).

Kiểm thử gồm 4 tầng, từ nhanh/rẻ đến chậm/đắt. Tầng nào bắt được lỗi thì lỗi không bao giờ phải chờ tới tầng sau.

| Tầng | Chạy ở đâu | Thời gian | Lệnh |
| :--- | :--- | :--- | :--- |
| **1. Blueprint guard** (tĩnh) | Mọi máy, CI Linux | vài giây | `make blueprint-check` |
| **2. E2E trên Simulator** | Mac / CI macOS | ~build + 1–2 phút | `make e2e` |
| **3. Gemini thật** (tùy chọn) | Mac / CI (thủ công) | ~1 phút, tốn quota | `make e2e-live` |
| **4. Phần cứng thật** (thủ công) | iPhone 15 Pro Max + kính | ~10 phút | Mục 4 bên dưới |

Cộng thêm **Test 6 (IPA)**: workflow *Build Unsigned IPA* tự chạy `scripts/blueprint/verify_ipa_symbols.sh` sau khi đóng gói; chạy tay: `make verify-ipa IPA=OpenVision.ipa`.

---

## 1. Ma trận truy vết: Blueprint → test

| Blueprint | Rủi ro | Tầng 1 (guard) | Tầng 2 (XCTest) | Tầng 4 (thủ công) |
| :--- | :--- | :--- | :--- | :--- |
| Bài học 1 – Deadlock ghi âm | 2 engine cùng tap bus 0 | Chỉ 3 file được phép tap mic; Recorder dùng tap chung | — (cần mic thật) | H5 |
| Bài học 2 – Volume HUD giật | Đổi category/mode, `setPreferredInput` đệ quy | `configureForGlasses` = `.playAndRecord`/`.default` + 4 option; route change không gọi `setPreferredInput` | — | H3 |
| Bài học 3 – Mic kính bị lờ | Wake word tiếng Việt, ưu tiên HFP Ray-Ban | Có biến thể `ô kê vi dơn`…; ưu tiên cổng Ray-Ban/Meta | `testWakeWordIsStrippedInEitherLanguage` | H1, H4 |
| Bài học 4 – TTS tự ngắt (echo) | Mic mở trước khi loa phát | Delay ≥ 350 ms; `.speaking` + khóa barge-in **trước** khi xếp câu (cả đường streaming) | `testSpokenAnswerPlaysCompletely…` (`isSpeaking` đồng bộ, không utterance nào bị hủy) | H2 |
| Bài học 5 – Đọc cụt chữ | Prompt "under 250 chars", cắt chữ "display" | Prompt 2–4 câu, không còn prompt cũ, không split chuỗi "display" | Toàn bộ nhóm *dual-channel* + `cleanSpokenAudio` + streaming prefix | H2 |
| Bài học 6 – Không đọc ảnh Photos | Thiếu `PHPhotoLibrary`, **chưa từng xin quyền** | Scanner tồn tại, quyền được xin thật, cửa sổ 120 s, đọc ảnh **gốc** | `BlueprintPhotoLibraryE2ETests` (thư viện ảnh thật, 12 MP, ảnh cũ không bị nhận nhầm) | H1 |
| Bài học 7 – Mất ngữ cảnh | REST không có lịch sử | 6 entry lịch sử, gửi kèm mỗi request | `testFollowUpOnTheSamePhoto…`, `testHistoryKeepsTheLastThreeExchanges` | H4 |
| Checklist 1 – Ảnh từ nút chụp | | | Ảnh 12 MP tới Gemini **nguyên byte** | H1 |
| Checklist 2 – Đọc 5–10 s liên tục | | | Phát TTS thật tới hết | H2 |
| Checklist 3 – Âm lượng | | Bài học 2 | — | H3 |
| Checklist 4 – Hỏi tiếp nối | | | Không upload lại ảnh, model vẫn thấy ảnh (2048 px) | H4 |
| Checklist 5 – Hỏi khi chưa chụp | | Prompt yêu cầu model nhắc bấm nút chụp | Prompt contract; live: `testUnrelatedQuestion…` | H6 |
| Checklist 6 – Symbol trong IPA | | | | `verify_ipa_symbols.sh` |
| Workflow – hỏi tự do song ngữ | Danh sách câu cố định, giọng đọc sai ngôn ngữ | Gemini nhận nguyên văn; prompt trả lời theo ngôn ngữ người hỏi | `testUnrelatedQuestionsGoVerbatim…`, `testVoiceFollowsAnswerLanguage`; live: VI→VI, EN→EN | H6, H7 |
| Không timeout | Upload ảnh lớn, model "nghĩ" lâu, key chết | Streaming + retry theo loại lỗi + deadline tổng | 429, key bị thu hồi, 503, `mediaResolution` bị từ chối, rớt mạng giữa chừng, mạng chết hẳn (< 15 s) | H8 |

> **Thay đổi so với checklist gốc §7 (theo yêu cầu chủ dự án):** trước đây Test 5 dựa trên một danh sách 40+ câu cố định để chặn câu hỏi "chay". Giờ Gemini nhận nguyên văn câu nói và **tự** nhận ra người dùng đang hỏi về thứ họ nhìn thấy mà chưa có ảnh, rồi nhắc bấm nút chụp — bằng đúng ngôn ngữ người dùng. Danh sách từ khóa chỉ còn dùng cho các backend nhỏ chạy trên máy.

---

## 2. Chạy E2E trên Simulator (tầng 2)

```bash
make e2e
```

Script `scripts/e2e/run-simulator-tests.sh` sẽ: chọn simulator iPhone iOS 18+ mới nhất (ưu tiên Pro Max), build một lần, cài app, **cấp quyền Ảnh** bằng `simctl privacy`, rồi chạy 4 bộ test Blueprint. Kết quả: `build/E2E.xcresult`.

Các bộ test:

- `BlueprintSolverTests` — logic thuần: tách SPOKEN/DISPLAY (mọi biến thể thẻ model hay trả về), lọc LaTeX trước khi đọc, chọn giọng theo ngôn ngữ, streaming prefix, phân loại lỗi HTTP, ảnh full-res/ảnh lịch sử, TTL ảnh 120 s, lệnh dừng song ngữ, wake word, hợp đồng System Prompt.
- `BlueprintGeminiE2ETests` — `GeminiLiveService` **thật** (dựng request, SSE, retry, lịch sử) với endpoint giả lập bằng `URLProtocol`, nối tiếp sang `TTSService` **thật**.
- `BlueprintPhotoLibraryE2ETests` — `RecentPhotoScanner` với **thư viện ảnh thật** của simulator. Tự bỏ qua (skip) nếu chưa có quyền Ảnh.
- `GeminiLiveSmokeTests` — gọi **Gemini thật**; chỉ chạy khi bật `OPENVISION_LIVE_GEMINI=1` (`make e2e-live`, hoặc tick *live_gemini* khi chạy workflow *E2E (Blueprint)* bằng tay).

Biến môi trường: `SUITE=all` (chạy toàn bộ test), `SIMULATOR_UDID=…` (chọn simulator).

---

## 3. CI

| Workflow | Khi nào | Nội dung |
| :--- | :--- | :--- |
| `e2e.yml` → *Blueprint guard* | Mọi PR, push `main`, chạy tay | Tầng 1 trên Ubuntu |
| `e2e.yml` → *Blueprint E2E (iOS simulator)* | Sau guard | Tầng 2 (+ tầng 3 nếu chọn) — upload `e2e-xcresult` |
| `ci.yml` | Mọi PR, push `main` | Build app + test cho iPhone thật (unsigned) |
| `build-ipa.yml` | Chạy tay | Guard → build Release → đóng gói IPA → **Test 6** → upload |

---

## 4. Quy trình trên phần cứng thật (tầng 4)

Chuẩn bị: iPhone 15 Pro Max (iOS 18+), kính đã ghép đôi Bluetooth và đồng bộ ảnh bằng Meta View, OpenVision cài bằng Sideloadly. Quyền **Ảnh = Toàn bộ ảnh** (nếu để *Giới hạn*, app sẽ báo — ảnh mới từ kính sẽ không thấy được). Mở Console.app trên Mac, lọc `OpenVision`, để đối chiếu các dòng log.

| # | Bước | Đạt khi | Log cần thấy |
| :--- | :--- | :--- | :--- |
| H1 | Nhìn một đề toán, bấm nút chụp trên gọng phải, chờ ~2 s, nói *"Ok Vision, giải câu này"* | Kính bắt đầu đọc lời giải; iPhone hiển thị LaTeX; **không** báo thiếu ảnh | `[RecentPhotoScanner] Using prefetched photo` hoặc `Successfully loaded photo (≈2–5 MB)` → `[GeminiLive] Attached image payload` |
| H2 | Nghe hết câu trả lời | Đọc 2–4 câu liên tục tới hết, không tự ngắt, không đọc ký hiệu `$`/`\frac` | Không có `Stop command detected` khi đang đọc |
| H3 | Trong lúc trả lời, quan sát thanh âm lượng iPhone & nghe loa kính | Thanh âm lượng không nhảy; không có tiếng click lặp | — |
| H4 | Trong 60 s, hỏi *"Tại sao lại ra kết quả đó?"* rồi *"Còn câu 2 thì sao?"* | Trả lời đúng ngữ cảnh bài trước; câu hỏi tiếp nối nhanh hơn câu đầu | `[GeminiLive] Photo already in conversation history — not re-uploading` |
| H5 | Bấm ghi hình POV trong lúc đang hội thoại | App không đơ, ghi âm vẫn chạy | `[Recorder] Using shared microphone tap` |
| H6 | Không chụp ảnh mới (hoặc chờ > 2 phút), hỏi *"giải câu này"*; rồi hỏi *"Thủ đô của Pháp là gì?"* | Câu 1: kính nói không thấy ảnh và nhắc bấm nút chụp. Câu 2: trả lời "Paris" bình thường | — |
| H7 | Chụp ảnh, hỏi bằng **tiếng Anh**: *"Ok Vision, what's the answer to question 3?"* | Trả lời bằng tiếng Anh, giọng đọc tiếng Anh | — |
| H8 | Bật Network Link Conditioner "3G" hoặc đi vào vùng sóng yếu, hỏi một câu có ảnh | Hoặc trả lời (chậm hơn), hoặc **kính nói** "Mạng đang chậm…" trong ≤ 2 phút — không treo "Thinking…" | `Sending request (attempt …)`, `Giving up after … ` nếu thất bại |

### Mẫu báo cáo

```
Ngày / build: ____   iOS: ____   Firmware kính: ____   Mạng: Wi-Fi / 5G / 4G
H1 ☐  H2 ☐  H3 ☐  H4 ☐  H5 ☐  H6 ☐  H7 ☐  H8 ☐
Thời gian từ lúc nói xong tới câu đầu tiên được đọc (H1): ____ s
Ghi chú / log lỗi:
```

---

## 5. Giới hạn đã biết

- Simulator không có Bluetooth/kính và không chạy được model MLX trên máy — các mục H1–H5 chỉ kiểm được trên phần cứng.
- Nhận dạng giọng nói (`SFSpeechRecognizer`) dùng **một** ngôn ngữ theo cài đặt của iPhone. Gemini được dặn rằng văn bản đến từ nhận dạng giọng nói và có thể sai/lẫn ngôn ngữ, nhưng câu tiếng Anh nói trên iPhone để tiếng Việt vẫn có thể bị phiên âm sai. Xem đề xuất trong phần tóm tắt thay đổi.
- `GeminiLiveSmokeTests` phụ thuộc vào model thật nên chỉ kiểm tra lỏng (ngôn ngữ, có đáp số, không LaTeX trong SPOKEN).
