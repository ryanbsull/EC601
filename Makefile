THREADS=1
MEMTIER=../memtier_benchmark/memtier_benchmark
MEMCACHED=../memcached/
MEMCACHED_APP=../memcached/memcached
SYS_MAP=../System.map-5.14.0-symbiote+
TGT=192.168.122.156
TGT_FLAGS=-t 1 -m 3072 -p 18080 -l $(TGT)
APP_INFO=info/app/
SYS_INFO=info/tgt_sys/
TEST_INFO=info/baseline/
SERVER_LAN_DEV=enp0s20f0u1
CLIENT_LAN_DEV=enp58s0u1
SERVER_LAN_IP=192.183.0.1
CLIENT_LAN_IP=192.183.0.2

all:
	@echo you wouldnt run a makefile without reading it, right?

connect_server:
	sudo ip link set $(SERVER_LAN_DEV) down
	sudo ip addr flush $(SERVER_LAN_DEV)
	sudo ip addr add $(SERVER_LAN_IP)/24 dev $(SERVER_LAN_DEV)
	sudo ip link set $(SERVER_LAN_DEV) up


connect_client:
	make connect_server SERVER_LAN_IP=$(CLIENT_LAN_IP) SERVER_LAN_DEV=$(CLIENT_LAN_DEV)

info:
	mkdir -p $(SYS_INFO)
	mkdir -p $(TEST_INFO)
	mkdir -p $(APP_INFO)

tgt_cmdline:
	ssh $(TGT) "cat /proc/cmdline" > $(SYS_INFO)cmdline.info

tgt_ifconfig:
	ssh $(TGT) "ifconfig" > $(SYS_INFO)ifconfig.info

tgt_nproc:
	ssh $(TGT) "nproc" > $(SYS_INFO)nproc.info

tgt_uptime:
	ssh $(TGT) "uptime" > $(SYS_INFO)uptime.info

tgt_cpu:
	ssh $(TGT) "cat /proc/cpuinfo" > $(SYS_INFO)cpu.info

tgt_uname:
	ssh $(TGT) "uname -srm" > $(SYS_INFO)uname.info

tgt_ps:
	echo "NPROC: " > $(SYS_INFO)ps.info
	ssh $(TGT) "ps aux | wc -l; ps aux" >> $(SYS_INFO)ps.info

tgt_info: info tgt_cmdline tgt_uname tgt_cpu tgt_ps tgt_ifconfig tgt_nproc

#BUILD MEMCACHED

build_app:
	make -C $(MEMCACHED)  -j16 MALLOC=glibc

# GET APP INFO

app_info:
	echo "MEMCACHED MD5: " > $(APP_INFO)memcached.info
	md5sum $(MEMCACHED_APP) >> $(APP_INFO)memcached.info

#INIT TARGET

init_server:$(MEMCACHED_APP)
	scp /lib64/libm.so.6 $(TGT):~
	scp /lib64/libevent-2.1.so.6 $(TGT):~
	scp $(MEMCACHED_APP) $(TGT):~
	ssh $(TGT) 'export LD_LIBRARY_PATH="/home/sym"; taskset -c 0 ./memcached $(TGT_FLAGS)' &
	sleep 1


KALLSYMLIB="../Apps/libs/kallsymlib/kallsymlib.o"
SYMLIB_DIR=../Symlib
SYMLIB_INCLUDE_DIR=$(SYMLIB_DIR)/include
SYMLIB_LINK=../Symlib/dynam_build/libSym.so

sc_lib.so: sc_lib.c 
	gcc -shared -fPIC -o $@ -L./$(SYMLIB_LINK) $< -I $(SYMLIB_INCLUDE_DIR)

build_test:
	gcc test.c -o test

test_interpose: sc_lib.so
	time (LD_LIBRARY_PATH=$(PWD) LD_PRELOAD=./$< ./test)

test_vanilla:
	which time
	time ./test

clean_lib:
	rm -f sc_lib.so test
#TEST TARGET

mitigate:
	./../Tools/bin/recipes/mitigate_all.sh

run_memcached:
	taskset -c 0 ./memcached -t $(THREADS) -m 3072 -p 18080 -l $(TGT)

run_memcached_sc: mitigate sc_lib.so
	taskset -c 0 sh -c 'LD_PRELOAD=./../Tools/bin/shortcut/sc_lib.so ./memcached -t $(THREADS) -m 3072 -p 18080 -l $(TGT)'

# Expected to crash TODO: fix core swapping mechanism when elevated
run_memcached_sc_multicore:
	LD_LIBRARY_PATH=$(PWD) LD_PRELOAD=./sc_lib.so ./memcached -t $(THREADS) -m 3072 -p 18080 -l $(TGT)

run_redis:
	taskset -c 0 ./../redis/src/redis-server --protected-mode no --save '' --appendonly no

run_redis_sc:
	taskset -c 0 sh -c 'LD_LIBRARY_PATH=$(PWD) LD_PRELOAD=./sc_lib.so ./../redis/src/redis-server --protected-mode no --save '' --appendonly no'

stress_server:
	./$(MEMTIER) -t $(THREADS) -s $(TGT) -p 18080 -n 10000 -P memcache_text -t 10 -n 10000 --hdr-file-prefix $(TEST_INFO)baseline 

kill_server:
	ssh $(TGT) "killall memcached"
	ssh $(TGT) "rm -f ~/memcached"

#test: tgt_info build_app app_info init_server stress_server kill_server
test: tgt_info build_app app_info stress_server
