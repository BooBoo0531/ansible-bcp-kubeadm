# SOC-MSE Kubernetes HA Cluster: Triển khai, Backup và Restore

Bộ Ansible tự động hóa toàn bộ bài tập BCP trên cluster kubeadm:

1. Dựng cluster Kubernetes HA gồm 3 node control-plane bằng kubeadm (containerd, Calico).
2. Deploy `nginx-hello-soc-mse` (2 replica, nội dung từ ConfigMap), expose qua Gateway có TLS do cert-manager cấp.
3. Backup etcd snapshot và `/etc/kubernetes/pki` vào thư mục có timestamp.
4. Xóa Deployment, restore etcd từ snapshot, rồi verify ứng dụng hoạt động trở lại.

Ngoài yêu cầu của đề, repo có thêm: VIP cho API server (HAProxy + Keepalived) kèm bằng chứng failover.

Log và bằng chứng của từng bước nằm trong [`report/`](report/), xem mục [Bằng chứng](#bằng-chứng).

## Môi trường

| Thành phần | Phiên bản / giá trị |
|---|---|
| Hypervisor | Virtual Machine Manager / libvirt (KVM), mạng `192.168.122.0/24` |
| Node | `cp1` 192.168.122.244, `cp2` 192.168.122.47, `cp3` 192.168.122.76; cả 3 là control-plane, 2 vCPU / 1900 MB RAM |
| Hệ điều hành | Ubuntu 24.04.4 LTS (kernel 6.8). Đề ghi Ubuntu 22.04; các playbook không phụ thuộc bản Ubuntu cụ thể |
| Kubernetes | v1.37.1 (đề cho tự chọn phiên bản), kubeadm, etcd 3.7.0 dạng stacked |
| Container runtime | containerd 2.2.1 (systemd cgroup driver) |
| CNI | Calico v3.33.0, pod CIDR `10.10.0.0/16` |
| Cân bằng tải API | HAProxy 2.8 + Keepalived 2.2.8, VIP `192.168.122.200:8443` |
| Gateway | Envoy Gateway v1.9.2 (kèm CRD Gateway API v1.6.1) |
| TLS | cert-manager v1.21.2, `Issuer` tự ký (self-signed) |
| Ansible | ansible-core 2.17 |

## Kiến trúc

```
                         client (curl / trình duyệt)
                                   │  https://hello.soc-mse.local:30443  (qua VIP hoặc IP node bất kỳ)
                                   ▼
                ┌──────── Envoy Gateway (Gateway "https-gateway", kết thúc TLS) ─────────┐
                │   chứng chỉ: nginx-tls-secret  ◄── cert-manager (selfsigned-issuer)     │
                └───────────────────────────────┬─────────────────────────────────────────┘
                                                │ HTTPRoute "/"
                                                ▼
                            Service nginx-hello-svc :80
                                   │
                ┌──────────────────┴──────────────────┐
                ▼                                     ▼
       pod nginx-hello-soc-mse              pod nginx-hello-soc-mse
       (index.html lấy từ ConfigMap nginx-hello-config)

  kubectl / kubelet ──► VIP 192.168.122.200:8443 (Keepalived) ──► HAProxy ──► kube-apiserver :6443 trên cp1, cp2, cp3
                                                                               etcd member trên cp1, cp2, cp3
```

## Cấu trúc repo

```
ansible.cfg                  Cấu hình Ansible (inventory, privilege escalation)
inventory/hosts.ini          3 VM control-plane
group_vars/all.yml           Biến cluster, ứng dụng, etcd, backup
playbooks/
  01-configure.yml           Hostname, /etc/hosts, tắt swap, kernel module, sysctl, containerd
  02-install-k8s.yml         kubelet, kubeadm, kubectl v1.37 từ pkgs.k8s.io
  03-loadbalancing.yml       HAProxy + Keepalived cho VIP của API server
  04-kubernetes-setup.yml    kubeadm init trên cp1, join cp2/cp3 làm control-plane, gỡ taint control-plane
  05-install-calico.yml      Calico CNI với pod CIDR lấy từ group_vars
  06-deploy-app.yml          Envoy Gateway, cert-manager, ứng dụng nginx, Gateway + HTTPRoute
  07-backup.yml              etcd snapshot + /etc/kubernetes/pki vào thư mục backup có timestamp
  08-delete-app.yml          Xóa Deployment nginx-hello-soc-mse (giả lập sự cố)
  09-restore.yml             Restore cả 3 member etcd từ snapshot
  10-verify.yml              Deployment tồn tại, 2 pod Running, curl trả về "Hello SOC-MSE"
  tasks/curl-gateway.yml     Task dùng chung: curl ứng dụng qua VIP và NodePort của Gateway
  roles/                     haproxy, keepalived, etcd_client, gateway_api, cert_manager, nginx_app
scripts/
  run-with-log.sh            Chạy playbook và lưu output vào report/<playbook>.log
  test-ha-failover.sh        Bằng chứng HA: tắt keepalived/haproxy trên cp1, VIP chuyển sang cp2
  test-curl.sh               Bằng chứng curl: HTTPS qua VIP và từng node, chứng chỉ TLS
backup/                      Bản sao backup trên máy điều khiển (git-ignore vì chứa private key)
report/                      Log và bằng chứng của từng bước
```

## Chuẩn bị

- 3 VM Ubuntu SSH được bằng user trong `inventory/hosts.ini`, có sudo không cần mật khẩu.
- Máy điều khiển có Ansible (ansible-core 2.17) và collection `community.general`.
- Mỗi VM tối thiểu khoảng 1.9 GB RAM: kubeadm không cho init khi RAM dùng được dưới 1700 MB.

Mọi lệnh đều chạy từ thư mục gốc của repo.

## Các bước thực hiện

| # | Bước | Lệnh | Log |
|---|---|---|---|
| 1 | Chuẩn bị VM | `ansible-playbook playbooks/01-configure.yml` | `report/01-configure.log` |
| 2 | Cài gói Kubernetes | `ansible-playbook playbooks/02-install-k8s.yml` | `report/02-install-k8s.log` |
| 3 | Cân bằng tải API (HAProxy + Keepalived) | `ansible-playbook playbooks/03-loadbalancing.yml` | `report/03-loadbalancing.log` |
| 4 | kubeadm init / join | `ansible-playbook playbooks/04-kubernetes-setup.yml` | `report/04-kubernetes-setup.log` |
| 5 | Calico CNI | `ansible-playbook playbooks/05-install-calico.yml` | `report/05-install-calico.log` |
| 6 | Deploy ứng dụng + Gateway + cert-manager | `ansible-playbook playbooks/06-deploy-app.yml` | `report/06-deploy-app.log` |
| 7 | Backup etcd + PKI | `ansible-playbook playbooks/07-backup.yml` | `report/07-backup.log` |
| 8 | Xóa Deployment | `ansible-playbook playbooks/08-delete-app.yml` | `report/08-delete-app.log` |
| 9 | Restore etcd | `ansible-playbook playbooks/09-restore.yml` | `report/09-restore.log` |
| 10 | Verify | `ansible-playbook playbooks/10-verify.yml` | `report/10-verify.log` |

Các log trong `report/` được ghi bằng `scripts/run-with-log.sh`. Script chạy lần lượt các playbook, lưu output
vào `report/<playbook>.log` và dừng ngay khi có playbook lỗi:

```bash
scripts/run-with-log.sh 01-configure 02-install-k8s 03-loadbalancing 04-kubernetes-setup 05-install-calico 06-deploy-app
scripts/run-with-log.sh 07-backup 08-delete-app 09-restore 10-verify
```

Chạy lại từng phần an toàn: `01`–`06` idempotent (`04` có guard bỏ qua init/join nếu cluster đã dựng sẵn), `07`
tạo thư mục backup timestamp mới mỗi lần, `10` chỉ đọc. Riêng `09` đưa etcd về đúng thời điểm snapshot — mọi
thay đổi diễn ra sau thời điểm đó sẽ mất, nên backup lại (`07`) trước khi restore nếu cluster có thay đổi mới.
Trên cluster đã dựng sẵn, chỉ cần chạy chuỗi thứ hai là đủ cho một vòng demo BCP (backup → giả lập sự cố →
restore → verify).

## Ứng dụng

- Deployment `nginx-hello-soc-mse`, 2 replica, image `nginx:alpine`.
- `index.html` (`<h1>Hello SOC-MSE</h1>`) lấy từ ConfigMap `nginx-hello-config`, mount vào `/usr/share/nginx/html`.
- Expose qua Gateway `https-gateway` (listener HTTPS 443, hostname `hello.soc-mse.local`) và HTTPRoute `nginx-hello-route`.
- Chứng chỉ TLS `nginx-hello-cert` do cert-manager cấp, lưu trong Secret `nginx-tls-secret`.
- Service của Envoy dùng `externalTrafficPolicy: Cluster` và NodePort cố định `30443` (EnvoyProxy `nodeport-proxy`,
  được GatewayClass `eg` tham chiếu), nên truy cập được qua VIP hoặc IP của bất kỳ node nào.

### Thử bằng curl

Lệnh đầy đủ, chạy được ngay trên mọi máy tới được mạng `192.168.122.0/24`, không cần chuẩn bị gì:

```bash
curl -k --resolve hello.soc-mse.local:30443:192.168.122.200 https://hello.soc-mse.local:30443/
# <h1>Hello SOC-MSE</h1>
```

Mỗi mảnh của lệnh thay cho một thứ hạ tầng mà lab này không có:

| Mảnh | Thay cho | Nếu thiếu |
|---|---|---|
| `-k` | CA được trust (chứng chỉ do cert-manager tự ký) | `SSL certificate problem: self-signed certificate` |
| `--resolve` | DNS server trỏ tên miền (lab không có DNS) | `Could not resolve host` |
| `:30443` | LoadBalancer nghe cổng 443 (lab chỉ có NodePort) | `connection refused` |
| `https://` + đúng tên | — (bản chất của listener TLS + SNI, production cũng phải đúng tên) | Envoy cắt kết nối |

Thêm tên miền vào `/etc/hosts` một lần thì gọi ngắn gọn:

```bash
echo "192.168.122.200 hello.soc-mse.local" | sudo tee -a /etc/hosts
curl -k https://hello.soc-mse.local:30443/
```

- Trên máy host không cần thêm gì: libvirt gắn sẵn `virbr0` (192.168.122.1) vào mạng của VM.
- Trong VM cũng curl được sau khi thêm dòng `/etc/hosts` tương tự; qua VIP hay IP node nào cũng được vì
  NodePort mở trên mọi node.
- Playbook và `scripts/test-curl.sh` cố tình dùng dạng đầy đủ `--resolve` kèm IP: lệnh không phụ thuộc
  `/etc/hosts` của máy chạy, nên repo chạy được ngay trên máy bất kỳ.

Phải dùng `https://` và đúng tên `hello.soc-mse.local`. Gọi `http://` hoặc gọi HTTPS bằng IP sẽ bị Envoy cắt
kết nối (`Connection reset by peer`), vì listener chỉ nhận TLS với SNI `hello.soc-mse.local`.

## Backup (`07-backup.yml`)

1. Cài `etcdctl`/`etcdutl` v3.7.0 lên các node (role `etcd_client`), vì kubeadm chạy etcd dạng static pod nên host không có sẵn.
2. Sinh một timestamp `YYYYmmdd-HHMMSS` dùng chung cho cả lần chạy.
3. Trên `cp1`: `etcdctl snapshot save`, kiểm tra bằng `etcdutl snapshot status`, ghi danh sách member etcd
   và trạng thái ứng dụng vào `backup-info.txt`.
4. Trên từng node: nén `/etc/kubernetes/pki` thành `pki-<node>.tar.gz` (chứng chỉ API server và etcd khác nhau giữa các node).
5. Tạo `SHA256SUMS`, rồi kéo toàn bộ về máy điều khiển với quyền `0700`/`0600`.

```
/opt/k8s-backup/<timestamp>/          trên từng node
backup/<timestamp>/
  cp1/  etcd-snapshot.db  pki-cp1.tar.gz  backup-info.txt  SHA256SUMS
  cp2/  pki-cp2.tar.gz  SHA256SUMS
  cp3/  pki-cp3.tar.gz  SHA256SUMS
```

## Restore (`09-restore.yml`)

Mặc định dùng thư mục mới nhất trong `backup/`, hoặc chỉ định bằng `-e backup_ts=<timestamp>`.
Cluster có 3 member etcd dạng stacked nên cả 3 đều được restore từ cùng một snapshot:

1. Kiểm tra `SHA256SUMS` trên máy điều khiển, copy snapshot lên từng node.
2. Dừng `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` và `etcd` trên cả 3 node bằng cách chuyển
   static pod manifest sang `/etc/kubernetes/manifests-stopped/`, chờ tới khi các cổng 6443, 10257, 10259, 2379 đóng.
3. Chuyển `/var/lib/etcd` sang `/var/lib/etcd.before-restore-<timestamp>`.
4. Chạy `etcdutl snapshot restore` trên từng node với `--name` và `--initial-advertise-peer-urls` riêng, `--initial-cluster`
   đầy đủ, `--initial-cluster-token` mới, cùng `--bump-revision --mark-compacted` để watch cache và informer tải lại dữ liệu.
5. Bật etcd trước, restart kubelet để kubelet chắc chắn khởi động lại static pod etcd, chờ `etcdctl endpoint health --cluster`,
   rồi bật các thành phần còn lại và restart kubelet.
6. Chờ `/readyz`, rồi restart kube-proxy, calico-node và CoreDNS (lý do ở mục [Vấn đề đã gặp](#vấn-đề-đã-gặp-và-cách-xử-lý)).
7. In trạng thái etcd (health, status, member list) và danh sách node.

## Verify (`10-verify.yml`)

Kiểm tra (assert):

- Deployment `nginx-hello-soc-mse` tồn tại và `readyReplicas == 2`.
- Có 2 pod `app=nginx-hello` ở trạng thái `Running`.
- `curl https://hello.soc-mse.local:30443` qua VIP trả về `HTTP 200` và `Hello SOC-MSE`.

Ngay sau restore, Envoy cần khoảng 1 phút để nhận địa chỉ mới của pod, nên bước curl được thử lại tối đa 3 phút
trước khi kết luận.

## Bằng chứng

### Đối chiếu yêu cầu của đề

| Yêu cầu | File bằng chứng | Dòng cần xem |
|---|---|---|
| Cài cluster bằng kubeadm | `report/04-kubernetes-setup.log`, `report/05-install-calico.log` | kubeadm init/join; bảng node: 3 node `Ready`, ROLES `control-plane`, runtime `containerd://2.2.1` |
| containerd, Calico | `report/01-configure.log`, `report/05-install-calico.log` | cấu hình containerd (`SystemdCgroup`); Calico triển khai, chờ `calico-node` Ready |
| nginx 2 replica, ConfigMap | `report/10-verify.log`, `report/12-curl.log` | `deployment.apps/nginx-hello-soc-mse 2/2`; nội dung ConfigMap `nginx-hello-config` |
| Gateway có TLS + cert-manager | `report/10-verify.log`, `report/12-curl.log` | `certificate.cert-manager.io/nginx-hello-cert True`; `SSL connection using TLSv1.3`; SAN `hello.soc-mse.local` |
| Backup etcd + PKI có timestamp | `report/07-backup.log` | bảng `etcdutl snapshot status`; `backup/<timestamp>/` |
| Xóa Deployment | `report/08-delete-app.log` | `NotFound`; `HTTP_CODE=503`; `Application is down as expected` |
| Restore etcd từ snapshot | `report/09-restore.log` | `Restoring from backup <timestamp>`; 3 member `started`; endpoint health |
| Verify | `report/10-verify.log` | `PASS: Deployment nginx-hello-soc-mse exists, 2 pods Running, curl returned 'Hello SOC-MSE'` |

### Bằng chứng curl (`scripts/test-curl.sh`, log `report/12-curl.log`)

```bash
scripts/test-curl.sh
```

Script ghi lại:

- Request HTTPS qua **VIP** và qua **từng node** (cp1, cp2, cp3): tất cả trả về `Hello SOC-MSE` với `HTTP=200`.
- Kết quả bắt tay TLS (`curl -v`): phiên bản TLS, `subjectAltName: host "hello.soc-mse.local" matched`, `HTTP/2 200`.
- Chứng chỉ Gateway trả về (`openssl s_client`): subject, issuer, SAN, ngày cấp và ngày hết hạn.
- Nội dung ConfigMap `nginx-hello-config`, trùng với nội dung trang trả về.
- 2 trường hợp Gateway từ chối: gọi `http://` (không TLS) và gọi HTTPS bằng IP (không có SNI).

Dòng cuối của log là `PASS: Hello SOC-MSE over HTTPS through the VIP and all 3 nodes`.

### Bằng chứng HA: tắt Keepalived / HAProxy (`scripts/test-ha-failover.sh`, log `report/11-ha-failover.log`)

```bash
scripts/test-ha-failover.sh
```

Script chạy 2 kịch bản trên node đang giữ VIP (cp1):

| Kịch bản | Cơ chế | Kết quả mong đợi |
|---|---|---|
| Tắt `keepalived` trên cp1 | cp1 ngừng gửi VRRP, cp2 (priority 90) lên làm MASTER | VIP chuyển sang cp2 sau vài giây |
| Tắt `haproxy` trên cp1 | `check_haproxy.sh` thất bại 2 lần liên tiếp, cp1 bị trừ 20 điểm (100 → 80 < 90) | VIP chuyển sang cp2 sau khoảng 6–9 giây |

Trong lúc VIP nằm ở cp2, script kiểm tra:

- **API Kubernetes** vẫn trả lời qua VIP: `kubectl get nodes` trên cp3 dùng `admin.conf`, có server là `https://192.168.122.200:8443`.
- **Ứng dụng** vẫn truy cập được qua VIP: `curl https://hello.soc-mse.local:30443` trả về `Hello SOC-MSE`.

Sau mỗi kịch bản, script bật lại dịch vụ trên cp1 và xác nhận VIP quay về cp1 (priority 100 cao nhất).
Nếu script dừng giữa chừng, `trap` vẫn bật lại `haproxy` và `keepalived` trên cp1.
Dòng cuối của log là `PASS: the VIP moved to cp2 ...`.

Kiểm tra tay tương đương:

```bash
# Trên cp1
sudo systemctl stop keepalived
# Trên cp2: VIP 192.168.122.200 xuất hiện
ip -br a show enp1s0
# Trên host: ứng dụng vẫn chạy qua VIP
curl -k --resolve hello.soc-mse.local:30443:192.168.122.200 https://hello.soc-mse.local:30443/
# Trên cp1: bật lại, VIP quay về cp1
sudo systemctl start keepalived
```

## Vấn đề đã gặp và cách xử lý

| Vấn đề | Nguyên nhân | Cách xử lý |
|---|---|---|
| Mạng pod trùng mạng node | Dải mặc định của Calico `192.168.0.0/16` chứa mạng libvirt `192.168.122.0/24` | Dùng pod CIDR `10.10.0.0/16` |
| `kubeadm init` báo thiếu RAM | VM 1.5 GB, kubeadm yêu cầu tối thiểu 1700 MB | Nâng mỗi VM lên 1900 MB |
| Pod ứng dụng `Pending` | 3 node đều là control-plane, mang taint `NoSchedule` | `04-kubernetes-setup.yml` gỡ taint |
| Xung đột CRD Gateway API | Envoy Gateway đã kèm CRD Gateway API, cài thêm bản riêng thì bị xung đột khi apply | Chỉ cài qua Envoy Gateway |
| Restore treo ở bước chờ etcd | Manifest etcd được trả lại với nội dung y hệt khi pod cũ vừa dừng, kubelet không khởi động lại | Restart kubelet ngay sau khi trả manifest etcd |
| Sau restore pod kẹt `ContainerCreating` | Khi API server tắt, kube-proxy thấy Service `kubernetes` mất endpoint và chặn `10.96.0.1`; sau đó nó giữ trạng thái cũ, Calico CNI và Felix không gọi được API | Restart kube-proxy, calico-node, CoreDNS sau khi API sẵn sàng |
| Verify trả về 503 ngay sau restore | Pod nhận IP mới, Envoy chưa cập nhật endpoint | Bước curl thử lại tối đa 3 phút |
| `Unauthorized`, event tuổi `<invalid>` | Đồng hồ VM lệch nhau (sau khi host ngủ), token do API server này cấp bị API server khác từ chối | Restart `systemd-timesyncd` trên các VM |
| Keepalived báo `Exec format error` | `check_haproxy.sh` thiếu shebang và thiếu `fi` | Viết lại script, kiểm tra bằng `systemctl is-active haproxy` |
| Chỉ một node trả lời NodePort | Envoy Gateway mặc định dùng `externalTrafficPolicy: Local` | EnvoyProxy `nodeport-proxy`: `Cluster` + NodePort cố định `30443` |

## Ghi chú

- **Trạng thái Gateway**: Service của Envoy là `LoadBalancer`, cluster local không có load balancer (ví dụ MetalLB),
  nên Gateway báo `Programmed=False (AddressNotAssigned)`. Traffic đi qua NodePort `30443` và vẫn hoạt động bình thường.
- **Phiên bản**: Envoy Gateway v1.9 và cert-manager v1.21 là bản mới nhất lúc làm bài. Bảng tương thích chính thức của
  2 project mới liệt kê tới Kubernetes 1.36.
- **Backup không được commit**: `backup/` chứa private key của CA và snapshot etcd có toàn bộ Secret, nên đã được `.gitignore`.
