function GetClone(){
	# En el caso que no se haya especificado inicialmente.
	if (aClone[LastPort]~/(0|1)/){} else { for(i=Port+1;i<=LastPort;i++){ aClone[i]=0 } }

	if (xClone==""){ xClone=Port+1; aClone[xClone]=1; return xClone }

	xClone++
	if (xClone>LastPort) xClone=Port+1
	
	for(l=xClone;l<=LastPort;l++){
		#xClone++
		#if (xClone>LastPort){ xClone=Port+1; aClone[xClone]=1; return xClone }
		#aClone[xClone]=1
		if (aClone[l]==0){ xClone=l; aClone[l]=1; return xClone }
	}

	for(k=Port+1;k<=xClone;k++){
		#xClone++
		#if (xClone>LastPort){ xClone=Port+1; aClone[xClone]=1; return xClone }
		#aClone[xClone]=1
		if (aClone[k]==0){ xClone=k; aClone[k]=1; return xClone }
	}

	return -1
}

BEGIN{
	Port=8081
	LastPort=8100
	
	
	ran=int(Port + rand() * (LastPort-Port+1))
	
	print ran
	
	for(j=1;j<=30;j++){
		aa=0
		aa=GetClone()
		print j, aa, aClone[aa]
		if (ran==aa){
			aClone[aa]=0
			ran=0
			print " ... enable " aa " " aClone[aa]
		}
		
	}

	print "List:"
	for (a in aClone){
		print a, aClone[a]
	}
}