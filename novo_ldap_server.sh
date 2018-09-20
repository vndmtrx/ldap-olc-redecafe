#!/usr/bin/env bash

#   Copyright 2018 Eduardo Rolim
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

## Instalação do OpenLDAP
## https://www.openldap.org/doc/admin24/slapdconf2.html
## https://wiki.rnp.br/pages/viewpage.action?pageId=69968769
## http://www.zytrax.com/books/ldap/ch6/
## https://aput.net/~jheiss/samba/ldap.shtml
## http://labs.opinsys.com/blog/2010/05/05/smbkrb5pwd-password-syncing-for-openldap-mit-kerberos-and-samba/
## https://www.itzgeek.com/how-tos/linux/centos-how-tos/configure-openldap-with-ssl-on-centos-7-rhel-7.html

if [[ $(id -u) -ne 0 ]] ; then echo "É necessário rodar como root/sudo." ; exit 1 ; fi

log="$(date +%Y-%m-%d_%H-%M)_instalacao-ldap-cafe.log"

yum install -y openldap compat-openldap openldap-clients openldap-servers openldap-servers-sql openldap-devel smbldap-tools

systemctl enable slapd.service
systemctl start slapd.service

firewall-cmd --permanent --add-port=389/tcp
firewall-cmd --permanent --add-port=636/tcp
firewall-cmd --reload

(

## Configuração Inicial

DOMINIO="dti.local"
DOMINIO_LDAP="dc=dti,dc=local"
DC="dti"
ORGANIZACAO="DTI"
DESCRICAO="Diretoria de Tecnologia da Informação"
CIDADE="Cidade"
UF="Estado"

SENHA_ADM="senha-adm"
SENHA_SHIB="senha-shib"
SENHA_USR="1234567890"

HASH_SENHA_ADM=$( slappasswd -h {SSHA} -u -s $SENHA_ADM )
HASH_SENHA_SHIB=$( slappasswd -h {SSHA} -u -s $SENHA_SHIB )
HASH_SENHA_USR=$( slappasswd -h {SSHA} -u -s $SENHA_USR )

# Descomentar e setar as variáveis caso deseje usar certificado já criado.
#VAR_USAR_CERT=1
#VAR_CERT_ROOT_CA=
#VAR_CERT_CRT=
#VAR_CERT_KEY=

#Caso deseje manter os arquivos LDIF gerados, comente esta linha
#VAR_EXCLUI_LDIFS=1

## Configuração inicial do banco e definição da senha do usuário ldapadm

printf "################### Configuração do Banco ###################\n\n"

cat > 01-backend.ldif <<_EOF_
dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: ${DOMINIO_LDAP}

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcRootDN
olcRootDN: cn=ldapadm,${DOMINIO_LDAP}

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${HASH_SENHA_ADM}
_EOF_

ldapmodify -Y EXTERNAL -H ldapi:/// -f 01-backend.ldif

## Configuração dos objetos mínimos para funcionamento da Rede CAFe

printf "################### Criação da árvore ${DOMINIO_LDAP} ###################\n\n"

cat > 02-raiz.ldif <<_EOF_
dn: ${DOMINIO_LDAP}
dc: ${DC}
objectClass: dcObject
objectClass: organization
objectClass: top
o: ${ORGANIZACAO}
description: ${DESCRICAO}

dn: ou=people,${DOMINIO_LDAP}
objectClass: organizationalUnit
ou: people
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 02-raiz.ldif

## Geração do certificado SSL

printf "################### Criação / Instalação do Certificado SSL ###################\n\n"

cat > 03-ssl.ldif <<_EOF_
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/openldap/certs/${DOMINIO}.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/openldap/certs/${DOMINIO}.key
_EOF_

if [ "${VAR_USAR_CERT}" == 1 ]; then ########################

cp "${CERT_ROOT_CA}" /etc/openldap/certs/${DOMINIO}.pem
cp "${CERT_CRT}" /etc/openldap/certs/${DOMINIO}.crt
cp "${CERT_KEY}" /etc/openldap/certs/${DOMINIO}.key

cat >> 03-ssl.ldif <<_EOF_
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/openldap/certs/${DOMINIO}.pem
_EOF_

else ########################################################

openssl req -new -x509 -nodes -out /etc/openldap/certs/${DOMINIO}.crt -keyout /etc/openldap/certs/${DOMINIO}.key -days 3650 -subj "/C=BR/ST=${UF}/L=${CIDADE}/O=${DESCRICAO}/CN=${DOMINIO}"

fi ##########################################################

chown -R ldap:ldap /etc/openldap/certs/${DOMINIO}* 

ldapmodify -Y EXTERNAL -H ldapi:/// -f 03-ssl.ldif

sed -i 's#ldap:///"$#ldap:/// ldaps:///"#' /etc/sysconfig/slapd

systemctl restart slapd

## Importação dos Schemas para uso da Rede CAFe

printf "################### Importação dos Schemas ###################\n\n"

ldapadd -Y EXTERNAL -H ldapi:/// -f schema/cosine.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f schema/nis.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f schema/inetorgperson.ldif

ldapadd -Y EXTERNAL -H ldapi:/// -f schema/eduperson.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f schema/breduperson.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f schema/schac-20061212-1.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f schema/samba.ldif

## Configuração dos Overlays

printf "################### Configuração dos Overlays Samba e MemberOf ###################\n\n"

cat > 04-overlays.ldif <<_EOF_
dn: cn=module{1},cn=config
objectClass: olcModuleList
cn: module{1}
olcModulePath: /usr/lib64/openldap
olcModuleLoad: smbk5pwd
olcModuleLoad: refint
olcModuleLoad: memberof
_EOF_

ldapadd -Y EXTERNAL -H ldapi:/// -f 04-overlays.ldif

cat > 05-smbk5pwd_conf.ldif <<_EOF_
dn: olcOverlay=smbk5pwd,olcDatabase={2}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSmbK5PwdConfig
objectClass: olcConfig
objectClass: top
olcOverlay: smbk5pwd
olcSmbK5PwdEnable: samba
_EOF_

ldapmodify -Y EXTERNAL -H ldapi:/// -f 05-smbk5pwd_conf.ldif

cat > 06-memberof_conf.ldif <<_EOF_
dn: olcOverlay=memberof,olcDatabase={2}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcMemberOf
objectClass: olcConfig
objectClass: top
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
_EOF_

ldapmodify -Y EXTERNAL -H ldapi:/// -f 06-memberof_conf.ldif

cat > 07-refint_conf.ldif <<_EOF_
dn: olcOverlay=refint,olcDatabase={2}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
objectClass: olcConfig
objectClass: top
olcOverlay: refint
olcRefintAttribute: memberof member manager owner
_EOF_

ldapmodify -Y EXTERNAL -H ldapi:/// -f 07-refint_conf.ldif

## Criação de usuário de exemplo na rede

printf "################### Criação do usuário de exemplo ###################\n\n"

cat > 08-usuario.ldif <<_EOF_
dn: uid=00123456,ou=people,${DOMINIO_LDAP}
objectClass: person
objectClass: inetOrgPerson
objectClass: brPerson
objectClass: schacPersonalCharacteristics
uid: 00123456
brcpf: 12345678900
brpassport: A23456
schacCountryOfCitizenship: Brazil
telephoneNumber: +55 12 34567890
mail: joao.silva@gmail.com
cn: Joao
sn: Silva
userPassword: ${HASH_SENHA_USR}
schacDateOfBirth:20181030
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 08-usuario.ldif

## Configurações extras de usuário segundo o Samba

printf "################### Adição dos dados do Samba do usuário ###################\n\n"

cat > 09-usr_samba.ldif <<_EOF_
dn: uid=00123456,ou=people,${DOMINIO_LDAP}
changetype: modify
add: objectClass
objectClass: sambaSamAccount
-
add: sambaSID
sambaSID: S-1-5-21-${RANDOM}-${RANDOM}-${RANDOM}-1102
_EOF_

ldapmodify -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 09-usr_samba.ldif

ldappasswd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -s ${SENHA_USR} "uid=00123456,ou=people,${DOMINIO_LDAP}"

## Configurações extras de usuário segundo o brEduPerson

printf "################### Adição dos dados do brEduPerson do usuário ###################\n\n"

cat > 10-usr_extras.ldif <<_EOF_
dn: braff=1,uid=00123456,ou=people,${DOMINIO_LDAP}
objectclass: brEduPerson
braff: 1
brafftype: aluno-graduacao
brEntranceDate: 20070205

dn: braff=2,uid=00123456,ou=people,${DOMINIO_LDAP}
objectclass: brEduPerson
braff: 2
brafftype: professor
brEntranceDate: 20070205
brExitDate: 20080330

dn: brvoipphone=1,uid=00123456,ou=people,${DOMINIO_LDAP}
objectclass: brEduVoIP
brvoipphone: 1
brEduVoIPalias: 2345
brEduVoIPtype: pstn
brEduVoIPadmin: uid=00123456,ou=people,${DOMINIO_LDAP}
brEduVoIPcallforward: +55 22 3418 9199
brEduVoIPaddress: 200.157.0.333
brEduVoIPexpiryDate:  20081030
brEduVoIPbalance: 295340
brEduVoIPcredit: 300000

dn: brvoipphone=2,uid=00123456,ou=people,${DOMINIO_LDAP}
objectclass: brEduVoIP
brvoipphone: 2
brvoipalias: 2346
brEduVoIPtype: celular
brEduVoIPadmin: uid=00123456,ou=people,${DOMINIO_LDAP}

dn: brbiosrc=left-middle,uid=00123456,ou=people,${DOMINIO_LDAP}
objectclass: brBiometricData
brbiosrc: left-middle
brBiometricData: ''
brCaptureDate: 20001212
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 10-usr_extras.ldif

## Criação de superusuário e usuário de leitura para o Shibboleth

printf "################### Criação do usuário admin ###################\n\n"

cat > 11-admin.ldif <<_EOF_
dn: cn=admin,${DOMINIO_LDAP}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
description: Administrador da base LDAP
userPassword: ${HASH_SENHA_ADM}
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 11-admin.ldif

printf "################### Criação do usuário leitor-shib ###################\n\n"

cat > 12-shib.ldif <<_EOF_
dn: cn=leitor-shib,${DOMINIO_LDAP}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: leitor-shib
description: Leitor da base para o shibboleth
userPassword: ${HASH_SENHA_SHIB}
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 12-shib.ldif

## Criação de grupos genéricos de permissões

printf "################### Configuração dos grupos admins e leitores ###################\n\n"

cat > 13-grupos.ldif <<_EOF_
dn: ou=groups,${DOMINIO_LDAP}
objectClass: organizationalUnit
objectClass: top
ou: groups

dn: cn=admins,ou=groups,${DOMINIO_LDAP}
objectClass: groupofnames
objectClass: top
cn: admins
member: cn=admin,${DOMINIO_LDAP}

dn: cn=leitores,ou=groups,${DOMINIO_LDAP}
objectClass: groupofnames
objectClass: top
cn: leitores
member: cn=leitor-shib,${DOMINIO_LDAP}
_EOF_

ldapadd -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 13-grupos.ldif

## Adicionar usuários nos grupos

printf "################### Adicionando usuário de exemplo no grupo admin ###################\n\n"

cat > 14-usr_grupos.ldif <<_EOF_
dn: cn=admins,ou=groups,${DOMINIO_LDAP}
changetype: modify
add: member
member: uid=00123456,ou=people,${DOMINIO_LDAP}
_EOF_

ldapmodify -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -H ldap:// -f 14-usr_grupos.ldif

## Configuração das regras de acesso do usuário do Shibboleth

printf "################### Criação das ACLs para acesso ao LDAP ###################\n\n"

cat > 15-acls.ldif <<_EOF_
dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcAccess
olcAccess: to attrs=userPassword,shadowLastChange 
  by dn.base="cn=admin,${DOMINIO_LDAP}" write 
  by dn.base="cn=leitor-shib,${DOMINIO_LDAP}" read
  by group.base="cn=admins,ou=groups,${DOMINIO_LDAP}" write 
  by group.base="cn=leitores,ou=groups,${DOMINIO_LDAP}" read 
  by self write 
  by anonymous auth 
  by * none 
-
add: olcAccess
olcAccess: to dn.regex="^uid=([^,]+),ou=people,${DOMINIO_LDAP}\$" 
  by dn.base="cn=leitor-shib,${DOMINIO_LDAP}" read 
  by dn.base="cn=admin,${DOMINIO_LDAP}" write 
  by group.base="cn=admins,ou=groups,${DOMINIO_LDAP}" write 
  by group.base="cn=leitores,ou=groups,${DOMINIO_LDAP}" read 
  by * none 
-
add: olcAccess
olcAccess: to dn.base="" 
  by * read 
-
add: olcAccess
olcAccess: to * 
  by dn.base="cn=admin,${DOMINIO_LDAP}" write 
  by dn.base="cn=leitor-shib,${DOMINIO_LDAP}" read 
  by group.base="cn=admins,ou=groups,${DOMINIO_LDAP}" write 
  by group.base="cn=leitores,ou=groups,${DOMINIO_LDAP}" read 
  by * none 
_EOF_

ldapmodify -Y EXTERNAL -H ldapi:/// -f 15-acls.ldif

printf "################### Consulta de Teste (LDAPS, MemberOf, ACL por Grupo) ###################\n\n"

LDAPTLS_REQCERT=never ldapsearch -x -D "cn=ldapadm,${DOMINIO_LDAP}" -w ${SENHA_ADM} -LLL -H ldaps:/// -b "uid=00123456,ou=people,${DOMINIO_LDAP}" dn memberof -s base

) | tee -a "${log}"

[[ "${VAR_EXCLUI_LDIFS}" == 1 ]] && rm -rfv *.ldif
