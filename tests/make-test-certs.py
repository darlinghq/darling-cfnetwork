#!/usr/bin/env python3
# Copyright (C) 2026 Lubos Dolezel
"""usage: make-test-certs.py OUTDIR
Writes self-signed certificates for 127.0.0.1 (NAME.pem, NAME.key): valid, expired, notyet
(valid from tomorrow) and wronghost (valid, but for a different host name)."""
import datetime, ipaddress, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

def make(out, name, start, end, san):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test.invalid" if name == "wronghost" else "127.0.0.1")])
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(start).not_valid_after(end)
            .add_extension(x509.SubjectAlternativeName([san]), critical=False)
            .sign(key, hashes.SHA256()))
    open("%s/%s.pem" % (out, name), "wb").write(cert.public_bytes(serialization.Encoding.PEM))
    open("%s/%s.key" % (out, name), "wb").write(key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))

now = datetime.datetime.now(datetime.timezone.utc)
day = datetime.timedelta(days=1)
ip = x509.IPAddress(ipaddress.ip_address("127.0.0.1"))
out = sys.argv[1]
make(out, "valid", now - day, now + 3 * day, ip)
make(out, "expired", now - 30 * day, now - day, ip)
make(out, "notyet", now + day, now + 30 * day, ip)
make(out, "wronghost", now - day, now + 3 * day, x509.DNSName("test.invalid"))
