//%attributes = {}
C_BLOB:C604($data)

CONVERT FROM TEXT:C1011("Hello world!"; "us-ascii"; $data)

$crc32:=CRC32 Get($data)

ASSERT:C1129($crc32=461707669)
//http://www.w3schools.com/php/func_string_crc32.asp