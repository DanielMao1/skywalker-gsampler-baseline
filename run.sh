echo "====livejournal===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/lj_loop.gr --gmgraph=true --hmgraph=false --umgraph=false --sage --n=512 --ngpu=1 --peritr=1 --batchnum=947
echo "====products===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/pr_loop.gr --gmgraph=true --hmgraph=false --umgraph=false --sage --n=512 --ngpu=1 --peritr=1 --batchnum=385
echo "====papers100m===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/papers100m_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true --sage --n=512 --ngpu=1 --peritr=1 --batchnum=2358
echo "====friendster===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/friendster_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true --sage --n=512 --ngpu=1 --peritr=1 --batchnum=12816



echo "====deepwalk===="
echo "====livejournal===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/lj_loop.gr --gmgraph=true --hmgraph=false --umgraph=false --rw=1 --k 1 --d 80 --n=1024 --ngpu=1  --batchnum=474
echo "====products===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/pr_loop.gr --gmgraph=true --hmgraph=false --umgraph=false --rw=1 --k 1 --d 80 --n=1024 --ngpu=1  --batchnum=193
echo "====papers100m===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/papers100m_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true --rw=1 --k 1 --d 80 --n=1024 --ngpu=1  --batchnum=1179
echo "====friendster===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/friendster_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true  --rw=1 --k 1 --d 80 --n=1024 --ngpu=1 --batchnum=6408


echo "====node2vec===="

echo "====livejournal===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/lj_loop.gr --gmgraph=true --hmgraph=false  --node2vec --rw=1 --k 1 --d 80 --n=1024 --ngpu=1  --batchnum=474
echo "====products===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/pr_loop.gr --gmgraph=true --hmgraph=false  --node2vec --rw=1 --k 1 --d 80 --n=1024 --ngpu=1 --batchnum=193

echo "====papers100m===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/papers100m_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true --node2vec --rw=1 --k 1 --d 80 --n=1024 --ngpu=1 --batchnum=1179
echo "====friendster===="
build/skywalker --bias=0 --ol=1 --input /home/ubuntu/data/friendster_with_loop.gr --gmgraph=false --hmgraph=false --umgraph=true -node2vec  --rw=1 --k 1 --d 80 --n=1024 --ngpu=1  --batchnum=6407