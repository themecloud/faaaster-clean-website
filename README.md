# Faaaster Clean Website

Script de vérification et réparation des checksums WordPress. Vérifie l'intégrité du core, des plugins et des thèmes WordPress, et réinstalle automatiquement les composants compromis.

## Fonctionnalités

- ✅ Vérifie les checksums du core WordPress
- ✅ Vérifie les checksums des plugins
- ✅ Vérifie les checksums des thèmes
- ✅ Supprime les fichiers malveillants qui ne devraient pas exister
- ✅ Réinstalle automatiquement les fichiers corrompus avec la même version
- ✅ Ignore les plugins/thèmes premium (non disponibles sur WordPress.org)
- ✅ Corrige les permissions et attributs des fichiers
- ✅ Scan et nettoyage des fichiers critiques (wp-config.php, mu-plugins, etc.)
- ✅ Mode dry-run pour prévisualiser les actions
- ✅ Logging dans un fichier et sur la console

## Prérequis

- WP-CLI installé et accessible dans le PATH
- Accès root ou sudo pour exécuter les commandes en tant que l'utilisateur web
- WordPress installé dans `/app/www` (par défaut) ou chemin personnalisé

## Installation

```bash
# Copier le script sur le serveur
cp wp-checksum-repair.sh /app/conf/

# Rendre le script exécutable
chmod +x /app/conf/wp-checksum-repair.sh
```

## Utilisation

```bash
# Utilisation basique (vérifie et répare core, plugins, thèmes)
./wp-checksum-repair.sh

# Mode dry-run (prévisualise sans modifier)
./wp-checksum-repair.sh --dry-run

# Spécifier un chemin WordPress personnalisé
./wp-checksum-repair.sh -p /var/www/html

# Spécifier un utilisateur différent (CentOS/RHEL)
./wp-checksum-repair.sh -u apache

# Spécifier un utilisateur différent (Nginx)
./wp-checksum-repair.sh -u nginx

# Combiner chemin et utilisateur
./wp-checksum-repair.sh -u apache -p /var/www/html

# Corriger les permissions sur tous les fichiers
./wp-checksum-repair.sh --fix-permissions

# Scanner et nettoyer les fichiers critiques (wp-config.php, etc.)
./wp-checksum-repair.sh --force-clean

# Combiner les options
./wp-checksum-repair.sh --fix-permissions --force-clean --verbose
```

## Arguments

| Argument | Description |
|----------|-------------|
| `-p, --path PATH` | Chemin vers l'installation WordPress (défaut: `/app/www`) |
| `-u, --user USER` | Utilisateur pour exécuter WP-CLI et définir les permissions (défaut: `www-data`) |
| `-d, --dry-run` | Prévisualise les actions sans effectuer de modifications |
| `-v, --verbose` | Affiche les détails supplémentaires |
| `-f, --force-clean` | Scanne et nettoie les fichiers critiques (wp-config.php, mu-plugins, drop-ins) |
| `--fix-permissions` | Corrige les permissions et propriétaires sur tous les fichiers WordPress |
| `-h, --help` | Affiche l'aide |

### Utilisateurs courants par environnement

| Environnement | Utilisateur |
|---------------|-------------|
| Debian/Ubuntu | `www-data` (défaut) |
| CentOS/RHEL | `apache` |
| Nginx | `nginx` |
| macOS | `_www` |
| Plesk | Utilisateur du domaine |
| cPanel | Utilisateur du compte |

## Comportement

### Vérification du Core
1. Vérifie les checksums du core WordPress
2. Si échec : détecte la version, supprime les fichiers malveillants, corrige les permissions, réinstalle le core

### Vérification des Plugins
1. Liste tous les plugins installés
2. Vérifie les checksums de chaque plugin
3. Les plugins avec checksums invalides sont réinstallés avec la même version
4. Les plugins premium/custom (non sur WordPress.org) sont ignorés avec un avertissement

### Vérification des Thèmes
1. Liste tous les thèmes installés
2. Vérifie les checksums de chaque thème
3. Les thèmes avec checksums invalides sont réinstallés avec la même version
4. Les thèmes premium/custom sont ignorés avec un avertissement

### Option --fix-permissions
- Supprime les attributs immutables (chattr -i / chflags nouchg)
- Change le propriétaire selon l'utilisateur spécifié (défaut: `www-data:www-data`)
- Définit les permissions : répertoires 755, fichiers 644
- wp-config.php : 640 (plus restrictif)

### Option --force-clean
Scanne et tente de nettoyer :
- `wp-config.php`
- `index.php`, `wp-settings.php`, `wp-load.php`, `wp-blog-header.php`
- Fichiers PHP dans `wp-content/` (drop-ins)
- Tous les fichiers dans `wp-content/mu-plugins/`

## Fichier de Log

Les actions sont enregistrées dans : `/app/conf/faaaster-clean.log`

## Sécurité

Le script utilise `--skip-plugins --skip-themes` pour toutes les commandes WP-CLI afin d'éviter l'exécution de code malveillant pendant la vérification.

## Exemples de Sortie

```
[INFO] ==========================================
[INFO]   WP Checksum Verification & Repair
[INFO] ==========================================
[INFO] WordPress Path: /app/www
[INFO] WP User: www-data
[INFO] Dry Run: false
[INFO] Force Clean: false
[INFO] Fix Permissions: false
[INFO] Log File: /app/conf/faaaster-clean.log
[INFO] ==========================================

[INFO] WordPress installation verified at: /app/www

[INFO] Verifying WordPress core checksums...
[WARNING] WordPress core checksum verification failed
[INFO] Detected WordPress version: 6.4.2
[INFO] Checking for rogue files that should not exist...
[WARNING] Found 15 rogue files to delete
[INFO] Deleting rogue file: wp-includes/malware.php
...
[SUCCESS] Deleted 15 rogue files
[INFO] Downloading WordPress core 6.4.2...
[SUCCESS] WordPress core 6.4.2 reinstalled successfully

[INFO] Verifying plugin checksums...
[INFO] Found 12 plugins to verify
[WARNING] Plugin 'akismet' (v5.0) failed checksum verification
[INFO] Reinstalling plugin 'akismet' version 5.0...
[SUCCESS] Plugin 'akismet' v5.0 reinstalled successfully
[WARNING] Skipping plugin 'premium-plugin' (not in WordPress.org repository)

[INFO] Verifying theme checksums...
[SUCCESS] All theme checksums verified successfully

[INFO] ==========================================
[INFO]           SUMMARY REPORT
[INFO] ==========================================
[SUCCESS] Core: OK
[WARNING] Skipped plugins (premium/custom): premium-plugin
[SUCCESS] All checksum verifications completed successfully
[INFO] Log file: /app/conf/faaaster-clean.log
[INFO] ==========================================
```

## Licence

MIT
