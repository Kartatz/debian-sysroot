#!/usr/bin/env bash

set -eu

declare -r workdir="${PWD}"
declare -r temporary_directory='/tmp/obggcc-sysroot'

[ -d "${temporary_directory}" ] || mkdir "${temporary_directory}"

cd "${temporary_directory}"

while read item; do
	declare distribution_version="$(jq '.distribution_version' <<< "${item}")"
	declare glibc_version="$(jq '.glibc_version' <<< "${item}")"
	declare linux_version="$(jq '.linux_version' <<< "${item}")"
	declare triplet="$(jq --raw-output '.triplet' <<< "${item}")"
	declare host=${triplet//-unknown/}
	declare packages="$(jq '.packages' <<< "${item}")"
	declare output_format="$(jq --raw-output '.output_format' <<< "${item}")"
	declare loader="$(jq --raw-output '.loader' <<< "${item}")"
	
	declare sysroot_directory="${workdir}/${triplet}${glibc_version}"
	[ -d "${sysroot_directory}" ] || mkdir "${sysroot_directory}"
	
	echo "- Generating sysroot for ${triplet} (glibc = ${glibc_version}, linux = ${linux_version}, debian = ${distribution_version})"
	
	while read package; do
		curl \
			--connect-timeout '10' \
			--retry '15' \
			--retry-all-errors \
			--fail \
			--silent \
			--show-error \
			--location \
			--remote-name \
			--url "${package}"
		
		for file in *.deb; do
			ar x "${file}"
			
			if [ -f './data.tar.gz' ]; then
				declare filename='./data.tar.gz'
			else
				declare filename='./data.tar.xz'
			fi
			
			tar --extract --file="${filename}"
			
			unlink "${filename}"
		done
	done <<< "$(jq --raw-output --compact-output '.[]' <<< "${packages}")"
	
	cp --recursive './usr/include' "${sysroot_directory}"
	cp --recursive './usr/lib' "${sysroot_directory}"
	
	if (( distribution_version >= 7 )); then
		mv "./lib/${host}/"* "${sysroot_directory}/lib"
	else
		mv "./lib/"* "${sysroot_directory}/lib"
	fi
	
	if (( distribution_version >= 7 )); then
		mv "${sysroot_directory}/lib/${host}/"* "${sysroot_directory}/lib"
		cp --recursive "${sysroot_directory}/include/${host}/"* "${sysroot_directory}/include"
		
		rm --recursive "${sysroot_directory}/lib/${host}"
		rm --recursive "${sysroot_directory}/include/${host}"
	fi
	
	cd "${sysroot_directory}/lib"
	
	find . -type l | xargs ls -l | grep '/lib/' | awk '{print "unlink "$9" && ln -s ./$(basename "$11") ./$(basename "$9")"}' | bash
	
	if [ "${triplet}" == 'alpha-unknown-linux-gnu' ] || [ "${triplet}" == 'ia64-unknown-linux-gnu' ]; then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ./libc.so.6.1 ./libc_nonshared.a  AS_NEEDED ( ./${loader} ) )" > './libc.so'
	else
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ./libc.so.6 ./libc_nonshared.a  AS_NEEDED ( ./${loader} ) )" > './libc.so'
	fi
	
	echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ./libpthread.so.0 ./libpthread_nonshared.a  )" > './libpthread.so'
	
	if (( distribution_version >= 9 )) && (( distribution_version <= 10 )) && [ "${triplet}" == 'x86_64-unknown-linux-gnu' ]; then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ./libm.so.6  AS_NEEDED ( ./libmvec_nonshared.a ./libmvec.so.1 ) )" > './libm.so'
	fi
	
	if (( distribution_version >= 11 )) && [ "${triplet}" == 'x86_64-unknown-linux-gnu' ]; then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ./libm.so.6  AS_NEEDED ( ./libmvec.so.1 ) )" > './libm.so'
	fi
	
	if [[ "${triplet}" == mips*-unknown-linux-gnu ]] || [ "${triplet}" == 'powerpc-unknown-linux-gnu' ] || [ "${triplet}" == 's390-unknown-linux-gnu' ] || [ "${triplet}" == 'sparc-unknown-linux-gnu' ]; then
		[ -f "${sysroot_directory}/include/linux/pim.h" ] && patch --directory="${sysroot_directory}" --strip='1' --input="${workdir}/patches/linux_pim.patch"
	fi
	
	cd "${temporary_directory}"
	
	rm --force --recursive ./*
	
	declare tarball_filename="${sysroot_directory}.tar.xz"
	
	echo "- Creating tarball at ${tarball_filename}"
	
	tar --directory="$(dirname "${sysroot_directory}")" --create --file=- "$(basename "${sysroot_directory}")" | xz  --compress -9 > "${tarball_filename}"
	sha256sum "${tarball_filename}" | sed "s|$(dirname "${sysroot_directory}")/||" > "${tarball_filename}.sha256"
	
	rm --force --recursive "${sysroot_directory}"
done <<< "$(jq --compact-output '.[]' "${workdir}/dist.json")"
