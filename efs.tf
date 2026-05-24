# EFS (Elastic File System) — filesystem POSIX réseau partagé entre tasks ECS.
#
# Pourquoi EFS ?
#   - Laravel ResponseCache + sessions utilisent le driver `file` (cohérent avec
#     l'approche "fichier HTML comme WordPress" choisie pour le projet).
#   - En multi-task ECS, chaque task a son filesystem isolé → cache local
#     incohérent (task A invalide, task B sert encore l'ancien).
#   - EFS = même filesystem vu par toutes les tasks → invalidation centralisée.
#
# Layout :
#   /cache    → mount sur /var/www/html/storage/framework/cache (ResponseCache + app cache)
#   /sessions → mount sur /var/www/html/storage/framework/sessions
#
# 2 access points pour scope l'accès par tâche (sécurité défense en profondeur).

resource "aws_efs_file_system" "main" {
  creation_token = "${local.name_prefix}-app-efs"

  performance_mode = var.efs_performance_mode
  throughput_mode  = var.efs_throughput_mode

  encrypted = true # chiffrement at rest (gratuit)

  # En dev on accepte la destruction. En prod TF refuse pour ne pas perdre
  # le cache de sessions actives (les users seraient déconnectés sinon).
  lifecycle {
    prevent_destroy = false # à passer à `true` quand on stabilise en prod
  }

  tags = {
    Name = "${local.name_prefix}-app-efs"
  }
}

# Mount targets : un point d'attache réseau par AZ pour que les tasks de chaque
# AZ puissent monter le FS. Toutes les tasks parlent au même backend EFS via NFS.
resource "aws_efs_mount_target" "main" {
  for_each = toset(var.efs_subnet_ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Access point pour le dossier /cache (ResponseCache + app cache Laravel).
# POSIX uid/gid = 33 (www-data sur Debian/Ubuntu) pour que PHP-FPM ait les droits.
resource "aws_efs_access_point" "cache" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = 33
    gid = 33
  }

  root_directory {
    path = "/cache"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0755"
    }
  }

  tags = {
    Name = "${local.name_prefix}-app-efs-cache"
  }
}

# Access point pour le dossier /sessions.
resource "aws_efs_access_point" "sessions" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = 33
    gid = 33
  }

  root_directory {
    path = "/sessions"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0755"
    }
  }

  tags = {
    Name = "${local.name_prefix}-app-efs-sessions"
  }
}

# Backup auto (optionnel, recommandé en prod). On crée toujours mais retention
# raccourcie en dev.
resource "aws_efs_backup_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = local.is_prod ? "ENABLED" : "DISABLED"
  }
}
