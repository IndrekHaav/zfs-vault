# Loading ZFS encryption keys on boot from Hashicorp Vault

## Background

### What is ZFS?

[ZFS](https://en.wikipedia.org/wiki/ZFS) is a combined file system and volume manager, with the primary design goal being to ensure data integrity. Originally developed by Sun Microsystems for the Solaris operating system, it is available for Linux as [OpenZFS](https://github.com/openzfs/zfs).

ZFS provides a number of features desirable in a storage system, such as data checksumming, snapshots, compression, deduplication, encryption, and more.

### What is Hashicorp Vault?

[Hashicorp Vault](https://www.vaultproject.io/) is an open-source solution for managing and programmatically providing access to secrets such as authentication tokens or encryption keys.

### Why this guide?

ZFS encryption keys have to be entered manually or loaded from a file that is accessible to the operating system. In the latter case, the keys can be stored on removable media that's only connected to the server during boot; for the former case, the [Arch Linux wiki](https://wiki.archlinux.org/title/ZFS#Unlock_at_boot_time:_systemd) has instructions for prompting for encryption keys during boot. Both approaches, however, require manual steps, which can be problematic if the server reboots unexpectedly (e.g. due to a power outage).

This guide aims to provide the basic steps needed to configure a Linux system to load ZFS encryption keys automatically on boot from a different server running Hashicorp Vault. It is meant for personal use (e.g. homelab), *not* as comprehensive instructions for a production-ready, enterprise-grade setup. It has been tested on Debian 11 and Ubuntu Server 20.04, but should also work (possibly with minor modifications) on older versions, as well as other similar distros like Raspbian or Proxmox.

### What this guide doesn't cover

This guide does **not** cover the following:

 - General Linux setup. It is assumed you have access to two servers (physical or virtual) running Debian (or a derivative distro like Ubuntu) - one that will be running OpenZFS, and one for Hashicorp Vault. The guide will refer to them as "alice" and "bob", respectively.
 - Proper setup and tuning of ZFS. This is highly dependent on hardware as well as workloads, and therefore out of the scope of this guide.
 - Likewise, proper hardening of Hashicorp Vault.
 - Encryption of the root filesystem.

### DISCLAIMER

This guide is provided in good faith and for informational purposes only. No claims are made or guarantees given that it will work on any particular combination of hardware and software, or that it will be kept up-to-date with new releases of OpenZFS or Hashicorp Vault. You will assume all responsibility for managing your servers, including the prevention of unauthorised access and safeguards against data loss.

## Setting up ZFS

The following steps should be done on the server "alice".

### Install OpenZFS

The steps for installing ZFS can differ depending on distro. Ubuntu is probably the easiest to start with, since OpenZFS is included by default, and the user-level tools can be installed with a single command:

```shell
$ sudo apt install zfsutils-linux
```

For more information, see the [Ubuntu wiki](https://wiki.ubuntu.com/ZFS).

For Debian, a few more steps are needed, as described in the [Debian wiki](https://wiki.debian.org/ZFS). For Debian 11, "buster" should be replaced with "bullseye".

The [OpenZFS wiki](https://openzfs.github.io/openzfs-docs/Getting%20Started/index.html) has installation instructions for a number of distros.

### Create pool and dataset

The exact command to create a ZFS pool can vary a lot depending on the drives installed in the system, the pool topology to be used, etc. Therefore, any command involving physical disks, copied and executed as-is, has the potential to at best not work, and at worst, destroy existing data.

For testing purposes, the following commands will create a pool called "tank", backed by a file on an existing disk:

```shell
$ sudo truncate -s 10G /root/dev1.img
$ sudo zpool create tank /root/dev1.img
```

Consult [`man zpool create`](https://openzfs.github.io/openzfs-docs/man/8/zpool-create.8.html) when preparing to set up a more permanent pool backed by physical devices.

To create an encrypted dataset called "data", execute the following command:

```shell
$ sudo zfs create -o encryption=on -o keyformat=passphrase tank/data
```

You will be prompted to enter a passphrase.

### Verify encryption

You can now write some data to the dataset. To verify that encryption works, reboot the server, then enter the following command:

```shell
$ sudo zfs list -o name,keystatus,mounted tank/data
```

The output should tell you that the key is unavailable and the dataset has not been mounted. If you try to `zfs mount tank/data`, you should also get an error saying that the key has not been loaded.

To manually load the key, run the following command:

```shell
$ sudo zfs load-key tank/data
```

This will again prompt you for the passphrase. After that, you can mount the dataset:

```shell
$ sudo zfs mount tank/data
```

The previous two commands can be combined as follows:

```shell
$ sudo zfs mount -l tank/data
```

## Setting up Vault

The following steps should be done on the server "bob".

### Prerequisites

A few packages are needed before installing Vault:

```shell
$ sudo apt install -y gnupg software-properties-common
```

### Install Vault

Hashicorp maintains packages for a number of Linux distributions. See [their documentation](https://learn.hashicorp.com/tutorials/vault/getting-started-install) for instructions.

You should also familiarise yourself with the [main concepts of Vault](https://www.vaultproject.io/docs/concepts).

### Configure Vault

This repo includes a simple configuration file (vault.hcl), that configures Vault to use the filesystem for storage and sets up the API to listen on HTTP port 8200. Copy the file to `/etc/vault.d/`.

Alternatively, modify the existing configuration file. Hashicorp's website has a [full list of configuration parameters](https://www.vaultproject.io/docs/configuration).

To have Vault start automatically on boot, run the following commands:

```shell
$ sudo systemctl daemon-reload
$ sudo systemctl enable vault.service
$ sudo systemctl start vault.service
```

### Initialise Vault

Before you can interact with Vault, set an environment variable pointing to the URL of the API:

```shell
$ export VAULT_ADDR='http://127.0.0.1:8200'
```

To initialise a new vault, enter the following command:

```shell
$ vault operator init
```

Note that by default Vault initialises the vault with 5 unseal keys, and requires at least 3 of them to be entered to unseal the vault. This might be unnecessarily complex for a personal or testing use case, but luckily can be changed by passing a few parameters to the above command. For example, to use only one unseal key:

```shell
$ vault operator init -n 1 -t 1
```

This will output the unseal key, required to unlock the vault after a reboot, as well as a root authentication token, which is required for any further interactions with the vault.

To continue, the vault needs to be unsealed:

```shell
$ vault operator unseal
```

You will be prompted to enter the unseal key(s). When that's done, continue by logging in with the root token:

```shell
$ vault login ROOT_TOKEN_HERE
```

### Store encryption keys

Vault supports a number of back-ends for storing secrets, but for the purposes of this guide, the [Key/Value store](https://www.vaultproject.io/docs/secrets/kv) will suffice. Enable it with the following command:

```shell
$ vault secrets enable -version=2 -path=secret kv
```

The K/V store supports nested keys with arbitrary values. The script in this repo that retrieves the keys, assumes the path will consist of "zfs", then the server's hostname, and finally the full path of the dataset. To store the encryption passphrase for the dataset "tank/data" on the server "alice", execute the following command:

```shell
$ vault kv put secret/zfs/alice/tank/data key=ZFS_PASSPHRASE
```

This scheme allows a single vault to store the keys for multiple datasets on multiple servers, as well as other secrets.

To retrieve the passphrase, enter the following command:

```shell
$ vault kv get secret/zfs/alice/tank/data
```

See the [documentation for the `vault kv` command](https://www.vaultproject.io/docs/commands/kv) for a full list of possible operations.

### Set up read-only access to the keys

It would obviously be a bad idea to have client devices authenticating with the root token. Limited, read-only access needs to be set up. In Vault, this is achieved with [policies](https://www.vaultproject.io/docs/concepts/policies). Copy the policy.hcl file included in the repo to your server, change the path as needed, and import the policy with the following command:

```shell
$ vault policy write alice /path/to/policy.hcl
```

For authentication, the [AppRole method](https://www.vaultproject.io/docs/auth/approle) works well for automated workflows. It needs to be enabled with the following command:

```shell
$ vault auth enable approle
```

Then a new role can be created and associated with the imported policy with:

```shell
$ vault write auth/approle/role/alice token_policies="alice" token_ttl=0s token_max_ttl=0s
```

Use the following commands to retrieve the RoleID and SecretID of the new role:

```shell
$ vault read auth/approle/role/alice/role-id
$ vault write -force auth/approle/role/alice/secret-id
```

## Load ZFS encryption keys from Vault

Back to the server "alice".

### Prerequisites

The process relies on [curl](https://curl.se/) and [jq](https://stedolan.github.io/jq/) to work, so make sure those are installed:

```shell
$ sudo apt install -y curl jq
```

### The main script

Copy the included zfs_load_keys.sh script to `/usr/local/sbin/` and make it executable with the following command:

```shell
$ sudo chmod +x /usr/local/sbin/zfs_load_keys.sh
```

The script first tries to authenticate with Vault using the given role and secret IDs, and get a temporary access token. If successul, it then enumerates all ZFS datasets that need their encryption keys to be loaded, requests each key and tries to load it.

### Vault credentials

Copy the included vault.env file to `/root/` and fill in the URL of your Vault instance, as well as the RoleID and SecretID from above. Also make sure to `chmod` it to 600.

### The systemd service

The included zfs-load-keys.service ties it all together. Copy it to `/etc/systemd/system/` and enable it with the following commands:

```shell
$ sudo systemctl daemon-reload
$ sudo systemctl enable zfs-load-keys.service
```

The service is activated on each boot, after the network is online and ZFS pools have been imported. It executes the main script, loading environment variables from the vault.env file. If successful, it tries to mount all ZFS datasets.

Test it out by rebooting the server. If everything went well, the datasets should be mounted successfully with no manual interaction required, and you should be able to read the data. If that's not the case, check the system logs and the output of `systemctl status zfs-load-keys` for any errors.
