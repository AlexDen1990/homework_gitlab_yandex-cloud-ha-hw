terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.89.0"
    }
  }
}

provider "yandex" {
  service_account_key_file = "key.json" 
  cloud_id  = "b1g92s9ht4r4o172qbs6"
  folder_id = "b1gkpeq3jh70cf8s8gc2"
  zone      = "ru-central1-a"
}

# Создание сервисного аккаунта
resource "yandex_iam_service_account" "sa" {
  name        = "vm-service-account"
  description = "Service account for VMs"
}

# Создание сети
resource "yandex_vpc_network" "network" {
  name = "web-network"
}

# Создание подсети
resource "yandex_vpc_subnet" "subnet" {
  name           = "web-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

# Создание 2 идентичных виртуальных машин
resource "yandex_compute_instance" "web_servers" {
  count = 2

  name        = "web-server-${count.index + 1}"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  # Разрешаем остановку для обновления параметров
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 2 
  }

  boot_disk {
    initialize_params {
      image_id = "fd8nvsua0sq94uqoep04" # Ubuntu 20.04
      size     = 8 # УМЕНЬШЕНО ДО 8 ГБ, чтобы не превысить квоту в 20 ГБ
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHovMq+3EsnDc0bhs8gsXPkRiVmB6zFJPkVPVRcc9xmd"
    user-data = <<-EOF
      #cloud-config
      packages:
        - nginx
      runcmd:
        - systemctl enable nginx
        - systemctl start nginx
        - echo "Hello from server ${count.index + 1}" > /var/www/html/index.html
      EOF
  }

  service_account_id = yandex_iam_service_account.sa.id
}

# Создание целевой группы
resource "yandex_lb_target_group" "web_target_group" {
  name = "web-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.web_servers
    content {
      subnet_id = target.value.network_interface[0].subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }

  depends_on = [yandex_compute_instance.web_servers]
}

# Создание сетевого балансировщика нагрузки
resource "yandex_lb_network_load_balancer" "web_balancer" {
  name = "web-balancer"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.web_target_group.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 80
        path = "/"
      }
    }
  }

  depends_on = [yandex_lb_target_group.web_target_group]
}

# ВЫВОД IP АДРЕСА БАЛАНСИРОВЩИКА
output "balancer_public_ip" {
  value = one(one(yandex_lb_network_load_balancer.web_balancer.listener).external_address_spec).address
}