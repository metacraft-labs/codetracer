int calc(int a, int b) {
	int sum = a + b;
	return sum;
}

int main() {
	int a = 0;
	for (int i = 0; i < 700000000; i +=1 ) {
		calc(1, 2);
		a += i;
	}
	return a;
}

