#!/bin/sh

# Define global variable
CERT_DIR="./"

CA_KEY="$CERT_DIR/ca.key"
CA_CRT="$CERT_DIR/ca.crt"

SERVER_KEY="$CERT_DIR/server.key"
SERVER_CSR="$CERT_DIR/server.csr"
SERVER_CRT="$CERT_DIR/server.crt"

CLIENT_KEY="$CERT_DIR/client.key"
CLIENT_CSR="$CERT_DIR/client.csr"
CLIENT_CRT="$CERT_DIR/client.crt"


gen_root_ca(){
	# CA Authority
	openssl req -nodes -x509 -days 3650 -newkey rsa:2048 -outform PEM -out \
		$CA_CRT -keyout $CA_KEY -sha256 -subj '/CN=MPTUN CA' >/dev/null 2>&1
}


gen_server_cert(){
	# Server certificate
	openssl req -nodes -days 3650 -newkey rsa:2048 -outform PEM -out \
		$SERVER_CSR -keyout $SERVER_KEY -sha256 -subj '/CN=MPTUN server' >/dev/null 2>&1
	# Sign request
	openssl x509 -days 3650 -req -in $SERVER_CSR -CA $CA_CRT -CAkey $CA_KEY \
		-CAcreateserial -clrext -out $SERVER_CRT -sha256 >/dev/null 2>&1	
}

gen_client_cert(){
	# Client certificate
	openssl req -nodes -days 3650 -newkey rsa:2048 -outform PEM -out \
		$CLIENT_CSR -keyout $CLIENT_KEY -sha256 -subj '/CN=MPTUN client' >/dev/null 2>&1
	# Sign request
	openssl x509 -days 3650 -req -in $CLIENT_CSR -CA $CA_CRT -CAkey $CA_KEY \
		-CAcreateserial -clrext -out $CLIENT_CRT -sha256 >/dev/null 2>&1	
}


create_certificates() {
	gen_root_ca
	gen_server_cert
	gen_client_cert
	return 0
}

create_certificates