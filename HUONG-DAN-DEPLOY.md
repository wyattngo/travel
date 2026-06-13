# Hướng dẫn deploy AuraTravel Kenya lên server

Ứng dụng Laravel 11, đóng gói Docker sẵn — lên server **chỉ cần 1 lệnh**.

---

## 1. Yêu cầu

- 1 server Linux (Ubuntu/Debian khuyến nghị), quyền `root` hoặc `sudo`.
- Mở port **80** và **443** (nếu dùng HTTPS), hoặc port **8000** (nếu chạy HTTP trực tiếp).
- Có sẵn `git` (hoặc tự copy mã nguồn lên server). **Không** cần cài sẵn PHP/Node/MySQL — Docker lo hết.

---

## 2. Deploy nhanh — 1 lệnh (server mới tinh)

```bash
# Đưa mã nguồn lên server
git clone <địa-chỉ-repo> travelvanlang
cd travelvanlang

# Chạy 1 lệnh: cài Docker → tạo secret → build → chạy → kiểm tra
./server-setup.sh bootstrap
```

Lệnh `bootstrap` tự động làm hết:
1. Cài **Docker Engine + Docker Compose** (qua get.docker.com).
2. Tạo file `.env.docker` từ mẫu, **tự sinh `APP_KEY` và mật khẩu DB** ngẫu nhiên.
3. Build image (gồm cả build assets frontend + cài composer).
4. Khởi động **app + MySQL**, tự **chạy migration + seed dữ liệu mẫu**.
5. Kiểm tra trang chủ trả về HTTP 200.

> Lưu ý: nếu Docker vừa được cài lần đầu, có thể cần **đăng xuất rồi đăng nhập lại** (hoặc chạy `newgrp docker`) để dùng `docker` không cần `sudo`. Trong lúc chưa đăng nhập lại, script tự dùng `sudo docker`.

Sau khi xong, app chạy ở `http://<IP-server>:8000`.

---

## 3. Bật HTTPS với tên miền (khuyến nghị cho production)

Trỏ DNS bản ghi **A/AAAA** của tên miền về IP server trước, rồi:

```bash
./server-setup.sh enable-https tours.example.com email-cua-ban@example.com
```

Script dựng **Caddy** đứng trước app, **tự xin chứng chỉ Let's Encrypt** (HTTPS tự động gia hạn). Sau đó app chạy ở `https://tours.example.com`.

Tắt HTTPS, quay lại HTTP thường:
```bash
./server-setup.sh disable-https
```

---

## 4. Các lệnh vận hành hằng ngày

| Lệnh | Tác dụng |
|------|----------|
| `./server-setup.sh status` | Xem trạng thái container |
| `./server-setup.sh logs app` | Xem log realtime của app (Ctrl+C để thoát) |
| `./server-setup.sh update` | Cập nhật mã mới (`git pull`) → build lại → khởi động lại |
| `./server-setup.sh restart` | Khởi động lại container |
| `./server-setup.sh stop` | Dừng container (vẫn giữ dữ liệu) |
| `./server-setup.sh backup` | Sao lưu DB ra `./backups/db-<thời-gian>.sql.gz` |
| `./server-setup.sh restore <file>` | Phục hồi DB từ file backup |
| `./server-setup.sh destroy` | Xoá container + image + **toàn bộ dữ liệu** (cẩn thận!) |
| `./server-setup.sh regen-secrets` | Đổi mới `APP_KEY` + mật khẩu DB |
| `./server-setup.sh help` | Xem tất cả lệnh |

Chạy không cần xác nhận (tự động hoá):
```bash
ASSUME_YES=true ./server-setup.sh update
```

---

## 5. Cấu hình quan trọng — file `.env.docker`

Script tự tạo file này với secret ngẫu nhiên. Bạn nên **kiểm tra/sửa** vài giá trị:

```env
APP_URL=https://tours.example.com   # đổi thành tên miền thật
APP_PORT=8000                       # port HTTP công khai (khi không dùng HTTPS/Caddy)
DB_SEED=true                        # seed dữ liệu mẫu lần đầu; tự bỏ qua khi đã có dữ liệu
MAIL_MAILER=log                     # đổi sang smtp + cấu hình MAIL_* nếu cần gửi email
STRIPE_KEY=... / STRIPE_SECRET=...  # thêm key Stripe thật nếu dùng thanh toán
```

> File `.env.docker` chứa **mật khẩu** — không commit lên git, không chia sẻ công khai.

---

## 6. Cách deploy thủ công (không dùng script)

Nếu server đã có sẵn Docker:

```bash
cp .env.docker.example .env.docker
# Sửa .env.docker: điền APP_KEY, DB_PASSWORD, MYSQL_ROOT_PASSWORD, APP_URL...
docker compose up -d --build
```

- Sinh nhanh `APP_KEY`: `echo "base64:$(openssl rand -base64 32)"`
- Sinh mật khẩu DB: `openssl rand -hex 16` (đặt giống nhau cho `DB_PASSWORD` và `MYSQL_ROOT_PASSWORD`).

Xem trạng thái / log:
```bash
docker compose ps
docker compose logs -f app
```

---

## 7. Tài khoản admin mẫu (sau khi seed)

- Email: `samadmin@gmail.com`
- Mật khẩu: `password`

> Nên đổi mật khẩu này ngay sau khi deploy production.

---

## 8. Xử lý sự cố thường gặp

| Hiện tượng | Nguyên nhân & cách xử lý |
|------------|--------------------------|
| `permission denied` khi gọi docker | User chưa thuộc nhóm docker → đăng xuất/đăng nhập lại, hoặc `newgrp docker`. |
| App cứ restart liên tục | Xem log: `./server-setup.sh logs app`. Thường do `.env.docker` sai (DB sai mật khẩu, thiếu `APP_KEY`). |
| Trang trắng / lỗi 500 | `docker compose logs app`; kiểm tra DB đã `healthy` chưa: `docker compose ps`. |
| Đổi mật khẩu DB nhưng app không vào được | MySQL chỉ tạo mật khẩu **lần đầu**. Nếu đã chạy rồi mà đổi pass, cần `./server-setup.sh destroy` (mất dữ liệu) hoặc đổi pass trực tiếp trong MySQL. |
| HTTPS không cấp được chứng chỉ | Kiểm tra DNS đã trỏ đúng IP và port 80/443 đang mở. |
| Port 8000 đã bị chiếm | Sửa `APP_PORT` trong `.env.docker` sang port khác rồi `./server-setup.sh deploy`. |

---

## Tóm tắt

```bash
# Lần đầu trên server mới:
./server-setup.sh bootstrap

# Có tên miền, bật HTTPS:
./server-setup.sh enable-https ten-mien.com email@example.com

# Cập nhật code về sau:
./server-setup.sh update
```
