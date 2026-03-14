# LoTW Signing — Implementation Notes

## Current State

The app supports **download-only** from LoTW: fetching QSL confirmations and new QSOs. Upload is not supported because LoTW requires digitally signed logs. Users must use TQSL to sign and upload ADIF files.

## How LoTW Signing Works

LoTW uses a PKI model. Each operator gets an X.509 certificate from ARRL's CA that binds their callsign to a public key. When they sign QSOs, LoTW verifies the signature came from the legitimate holder of that callsign.

### Certificate Lifecycle

1. **Request**: Operator generates an RSA key pair and submits a certificate request (.tq5 file) to ARRL
2. **Verification**: US licensees receive a postcard with an 8-character code; non-US licensees submit proof of license + government ID
3. **Issuance**: ARRL returns a signed X.509 certificate (.tq6 file) which must be matched with the private key on the original machine
4. **Portability**: Certificates can be exported as PKCS#12 (.p12) bundles for transfer between computers/applications

### Key/Certificate Formats

- **Private keys**: RSA 1024-bit, PEM-encoded PKCS#8 (optionally encrypted with 3DES-CBC)
- **Certificates**: Standard X.509 in PEM format (DER-encoded, base64)
- **Portable bundles**: PKCS#12 (.p12) containing private key + certificate + CA chain

### Signing Algorithm

**RSA with SHA-1** (PKCS#1 v1.5 padding), confirmed from TQSL source (`openssl_cert.cpp` — `tqsl_signDataBlock`).

The signed data (SIGNDATA) is constructed by concatenating these fields in order, all uppercased:

1. Station location fields (US_STATE or CA_PROVINCE, CQ zone, grid square, IOTA, ITU zone, county)
2. BAND
3. BAND_RX (optional)
4. CALL (remote station)
5. FREQ (optional)
6. FREQ_RX (optional)
7. MODE
8. PROP_MODE (optional)
9. QSO_DATE
10. QSO_TIME (with "Z" suffix)
11. SAT_NAME (optional)

The certificate serial number is appended to the sign data before signing.

### The .tq8 File Format

A gzip-compressed text file with four ADIF-like sections:

1. **TQSL_IDENT** — Version info
2. **tCERT** — Base64-encoded DER X.509 certificate
3. **tSTATION** — Station location: callsign, DXCC entity, grid, CQ/ITU zones, state/county
4. **tCONTACT records** — Each QSO with `<SIGNDATA:n>` and `<SIGN_LOTW_V2.0:n:6>` fields

Upload endpoint: `POST https://lotw.arrl.org/lotw/upload` (multipart form).

## Feasibility Assessment

**Signing is technically feasible.** It has been independently reimplemented outside of TQSL by Cloudlog/Wavelog (PHP).

### Apple Framework Support

| Component | API | Status |
|---|---|---|
| Import .p12 | `SecPKCS12Import()` | Supported |
| Extract private key | `SecIdentityCopyPrivateKey()` | Supported |
| RSA-SHA1 signing | `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15SHA1)` | Supported |
| Base64 encoding | `Data.base64EncodedString()` | Built-in |
| Gzip compression | `Data` with compression / zlib | Built-in |
| HTTP upload | `URLSession` multipart | Built-in |
| X.509 cert reading | `SecCertificate` | Supported |
| Key storage | Keychain Services | Supported |

### Risks

- **SHA-1 deprecation**: SHA-1 is cryptographically weak. Apple still supports `rsaSignatureDigestPKCS1v15SHA1` but could deprecate it. TQSL already had to add `OPENSSL_ENABLE_SHA1_SIGNATURES` workarounds on Linux. If Apple removes SHA-1 support, we'd need to bundle OpenSSL/BoringSSL.
- **RSA-1024 keys**: LoTW uses 1024-bit RSA, considered insecure by modern standards. Apple may restrict operations with keys this small in future OS versions.
- **Field ordering**: The exact normalized field order and formatting must match LoTW's expectations precisely. Getting this wrong means rejected uploads. Cloudlog source is a working reference.

## Implementation Plan

### Phase 1: P12 Import (MVP)

Users export a .p12 from TQSL and import it into the app. The app handles signing and upload from there. Users still need TQSL once for initial certificate setup.

1. Add a .p12 file importer to Settings (file picker / share sheet)
2. Use `SecPKCS12Import` to extract `SecIdentity` (key + cert)
3. Store the identity in the Keychain
4. Implement SIGNDATA construction following the field order above
5. Sign with `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15SHA1)`
6. Assemble .tq8 file (gzipped ADIF with tCERT, tSTATION, tCONTACT sections)
7. Upload via `URLSession` multipart POST to `https://lotw.arrl.org/lotw/upload`
8. Parse response for success/failure (`<!-- .UPL. result -->` HTML comments)

### Phase 2: Full Certificate Management (Optional)

Eliminate TQSL dependency entirely:

1. Generate RSA key pair on-device
2. Create .tq5 certificate request file
3. Submit to ARRL via their web upload endpoint
4. Handle verification code entry (postcard flow)
5. Import .tq6 certificate response, match with local private key

This is significantly more complex UX but would make the app fully self-contained.

## Reference Sources

- TQSL source (SourceForge): `trustedqsl/tqsl` — `src/openssl_cert.cpp` (signing), `src/tqslconvert.cpp` (SIGNDATA construction)
- Cloudlog (PHP reimplementation): `magicbug/Cloudlog` — `application/controllers/Lotw.php`
- LoTW developer docs: `https://lotw.arrl.org/lotw-help/developer-tq8/`, `https://lotw.arrl.org/lotw-help/developer-submit-qsos/`
- Aether (macOS app that links tqsllib): `https://help.aetherlog.com/lotw/exportp12/`
