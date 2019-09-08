#
#	References:
#	https://monades.roperzh.com/rediscovering-make-automatic-variables/
#
# Keep all intermediate artifacts, should add a few to prune later...
.SECONDARY:

# Path to the Makefile
APP_PATH ?= $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

# filename of first prerequisite ex. sample.fq
PREREQ = $(<F)

# filename of the target generated from the prerequisite ex. sample.bam
TARGET = $(@F)

# Run as the calling user, data directories group and map the sample
# into /data and references into /references
DOCKER_RUN = docker run -it --rm --cpus="32" \
		--user `id -u`:`stat -c "%g" data/` \
		-v `realpath data/references`:/references \
		-v `realpath $(@D)`:/data

#
# General recipes
#

%.md5: %
	echo "Calculating md5 of $(<) for provenance..."
	md5sum $(<) > $(<).md5

#
# Download references
#

data/references/hg38.fa:
	echo "Downloading hg38 reference and indexing..."
	mkdir -p data/references
	wget -N -P data/references https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
	gunzip data/references/hg38.fa.gz
	md5sum -c $(APP_PATH)hg38.fa.md5

data/references/hg38.fa.fai: data/references/hg38.fa
	$(DOCKER_RUN) \
		quay.io/ucsc_cgl/samtools@sha256:2abed6c570ef4614fbd43673ddcdc1bbcd7318cb067ffa3d42eb50fc6ec1b95f \
		faidx /references/hg38.fa

#
# Download NA12878 chr11 from https://github.com/nanopore-wgs-consortium
# and convert to fq as a test sample
#

data/na12878-chr11/na12878-chr11.fq.gz:
	echo "Downloading na12878 chr11 bam..."
	mkdir -p data/na12878-chr11 data/references
	wget -O data/na12878-chr11/na12878-chr11.original.bam \
		http://s3.amazonaws.com/nanopore-human-wgs/chr11.sorted.bam
	echo "Converting bam to fq..."
	$(DOCKER_RUN) \
		quay.io/ucsc_cgl/samtools@sha256:2abed6c570ef4614fbd43673ddcdc1bbcd7318cb067ffa3d42eb50fc6ec1b95f \
		fastq na12878-chr11.original.bam -0 na12878-chr11.fq.gz

#
# Map sample to hg38 creating a sorted and indexed bam
#

%.sam: %.fq.gz %.fq.gz.md5 data/references/hg38.fa data/references/hg38.fa.fai
	echo "Mapping reads to reference genome..."
	$(DOCKER_RUN) \
		tpesout/minimap2@sha256:5df3218ae2afebfc06189daf7433f1ade15d7cf77d23e7351f210a098eb57858 \
		-ax map-ont --MD /references/hg38.fa $(PREREQ)
	mv $(@D)/minimap2.sam $(@)

%.bam: %.sam
	$(DOCKER_RUN) \
		quay.io/ucsc_cgl/samtools@sha256:2abed6c570ef4614fbd43673ddcdc1bbcd7318cb067ffa3d42eb50fc6ec1b95f \
		view -S -b $(PREREQ) -o $(TARGET)

%.sorted.bam: %.bam
	$(DOCKER_RUN) \
		quay.io/ucsc_cgl/samtools@sha256:2abed6c570ef4614fbd43673ddcdc1bbcd7318cb067ffa3d42eb50fc6ec1b95f \
		sort $(PREREQ) -o $(TARGET)

%.sorted.bam.bai: %.sorted.bam
	$(DOCKER_RUN) \
		quay.io/ucsc_cgl/samtools@sha256:2abed6c570ef4614fbd43673ddcdc1bbcd7318cb067ffa3d42eb50fc6ec1b95f \
		index $(PREREQ)

#
# Call variants against hg38
#

%.sniffles.vcf: %.sorted.bam data/references/hg38.fa
	echo "Calling variants with sniffles..."
	$(DOCKER_RUN) \
		quay.io/biocontainers/sniffles@sha256:98a5b91db2762ed3b8aca3bffd3dca7d6b358d2a4a4a6ce7579213d9585ba08a \
		sniffles -m /data/$(PREREQ) -v /data/$(TARGET) --genotype

%.svim.vcf: %.sorted.bam %.sorted.bam.bai data/references/hg38.fa
	echo "Calling variants with svim..."
	$(DOCKER_RUN) \
		quay.io/biocontainers/svim@sha256:4239718261caf12f6c27d36d5657c13a2ca3b042c833058d345b04531b576442 \
		svim alignment /data/svim /data/$(PREREQ) /references/hg38.fa --sample $(TARGET)
	mv $(@D)/svim/final_results.vcf $(@)

data/references/clairvoyante:
	echo "Downloading clairvoyante trained model..."
	cd data/references && curl http://www.bio8.cs.hku.hk/trainedModels.tbz | tar -jxf -
	mv data/references/trainedModels data/references/clairvoyante

# REMIND: Remove start/end and sort how to do all chromosomes when with GPU
%.clairvoyante.vcf: \
	%.sorted.bam %.sorted.bam.bai data/references/clairvoyante data/references/hg38.fa
	echo "Calling variants with clairvoyante..."
	$(DOCKER_RUN) \
		-e CUDA_VISIBLE_DEVICES="" \
		lifebitai/clairvoyante:latest \
		pypy /opt/conda/bin/clairvoyante/callVarBam.py \
			--chkpnt_fn /references/clairvoyante/fullv3-illumina-novoalign-hg001+hg002-hg38/learningRate1e-3.epoch500 \
			--ref_fn /references/hg38.fa \
			--bam_fn /data/$(PREREQ) \
			--call_fn /data/$(TARGET) \
			--ctgName chr11 \
			--ctgStart 1000000 \
			--ctgEnd 1010000

benchmark:
	# Compare the region we tried to call variants on to the ground truth from GIAB
	# First download the ground truth
	wget -N -P data/references https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/latest/GRCh38/HG002_GRCh38_GIAB_highconf_CG-Illfb-IllsentieonHC-Ion-10XsentieonHC-SOLIDgatkHC_CHROM1-22_v.3.3.2_highconf_triophased.vcf.gz
	wget -N -P data/references https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/latest/GRCh38/HG002_GRCh38_GIAB_highconf_CG-Illfb-IllsentieonHC-Ion-10XsentieonHC-SOLIDgatkHC_CHROM1-22_v.3.3.2_highconf_triophased.vcf.gz.tbi
	wget -N -P data/references ftp://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/latest/GRCh38/HG002_GRCh38_GIAB_highconf_CG-Illfb-IllsentieonHC-Ion-10XsentieonHC-SOLIDgatkHC_CHROM1-22_v.3.3.2_highconf_noinconsistent.bed
	# Compress and index our variant set - should be up in variant calling?
	docker run -it --rm --cpus="$(CPU)" -v `realpath data/$(ID)`:/data \
		-v `realpath data/references`:/references \
		--user `id -u`:`stat -c "%g" data/` \
		quay.io/biocontainers/bcftools@sha256:d9360c33b0771a49f49db174d03e0e49c8720eef34330be4c0371ca54fbb8f7b \
		bcftools view -Oz -o /data/$(ID).hg38_lite.vcf.gz /data/$(ID).hg38_lite.vcf
	docker run -it --rm --cpus="$(CPU)" -v `realpath data/$(ID)`:/data \
		-v `realpath data/references`:/references \
		--user `id -u`:`stat -c "%g" data/` \
		quay.io/biocontainers/bcftools@sha256:d9360c33b0771a49f49db174d03e0e49c8720eef34330be4c0371ca54fbb8f7b \
		bcftools index /data/$(ID).hg38_lite.vcf.gz
	# Find the variants found in both
	mkdir -p data/$(ID)/diff
	docker run -it --rm --cpus="$(CPU)" -v `realpath data/$(ID)`:/data \
		-v `realpath data/references`:/references \
		--user `id -u`:`stat -c "%g" data/` \
		quay.io/biocontainers/bcftools@sha256:d9360c33b0771a49f49db174d03e0e49c8720eef34330be4c0371ca54fbb8f7b \
		bcftools isec --regions chr20:1000000-1010000 \
		-p /data/diff -n=2 \
		/data/$(ID).hg38_lite.vcf.gz \
		/references/HG002_GRCh38_GIAB_highconf_CG-Illfb-IllsentieonHC-Ion-10XsentieonHC-SOLIDgatkHC_CHROM1-22_v.3.3.2_highconf_triophased.vcf.gz

