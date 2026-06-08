import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nfc_manager/nfc_manager.dart';

// ==========================================
// CONFIGURATION: SETUP YOUR SUPABASE DETAILS
// ==========================================
const String supabaseUrl = 'https://okhcuocbflkmelugvvmh.supabase.co';
const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9raGN1b2NiZmxrbWVsdWd2dm1oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5MjgyMzIsImV4cCI6MjA5NjUwNDIzMn0.hdLKtrhkZOmm7SebMlMlBGjTY8_Sg5zdjXOCPdpav1o';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool isSupabaseConfigured = false;
  
  if (supabaseUrl != 'YOUR_SUPABASE_URL' && 
      supabaseAnonKey != 'YOUR_SUPABASE_ANON_KEY' &&
      supabaseUrl.isNotEmpty && 
      supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
      isSupabaseConfigured = true;
    } catch (e) {
      debugPrint('Supabase Initialization Failed: $e');
    }
  }

  runApp(CashierApp(isSupabaseConfigured: isSupabaseConfigured));
}

class CashierApp extends StatelessWidget {
  final bool isSupabaseConfigured;

  const CashierApp({super.key, required this.isSupabaseConfigured});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Wisata POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19), // Deep Obsidian Dark
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1), // Electric Indigo
          secondary: Color(0xFFEC4899), // Neon Pink
          surface: Color(0xFF151D30), // Sleek Dark Blue/Grey
          background: Color(0xFF0B0F19),
        ),
      ),
      home: CashierHomePage(isSupabaseConfigured: isSupabaseConfigured),
    );
  }
}

enum TransactionStatus {
  waitingForInput,
  waitingForCard,
  processing,
  success,
  failed,
}

class CashierHomePage extends StatefulWidget {
  final bool isSupabaseConfigured;

  const CashierHomePage({super.key, required this.isSupabaseConfigured});

  @override
  State<CashierHomePage> createState() => _CashierHomePageState();
}

class _CashierHomePageState extends State<CashierHomePage> with TickerProviderStateMixin {
  // Access and Navigation State
  bool _isAdminMode = false;
  bool _isInitialized = false;
  int _currentTab = 0; // Index mapping adapts depending on _isAdminMode

  // Global State Machine variables
  TransactionStatus _currentStatus = TransactionStatus.waitingForInput;
  String _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
  
  // Amounts
  int _cashierAmount = 0;
  int _topUpAmount = 0;
  
  // NFC Card / RFID states
  String? nfcUid;
  int? remainingSaldo; // Cashier mode success variable
  int? loadedNewSaldo; // Top up mode success variable
  String? touristName; // Loaded name on card detection

  // Dynamic Merchant / Warung variables
  List<Map<String, dynamic>> _merchantsList = [];
  int? _selectedMerchantId;

  // Merchant Dashboard Data variables (Merchant role)
  bool _isLoadingDashboard = false;
  int _totalEarnings = 0;
  int _totalTransactionsCount = 0;
  List<Map<String, dynamic>> _recentTransactions = [];

  // Admin Overview Data variables (Admin role)
  bool _isLoadingAdminDashboard = false;
  int _totalTopUpsSum = 0;
  int _totalSpendingsSum = 0;
  List<Map<String, dynamic>> _bestSellingMerchants = [];
  List<Map<String, dynamic>> _allTransactionsGlobal = [];

  // Animation controller for pulsing card reader concentric rings
  late AnimationController _pulseController;

  // Tab mappings helper getters
  bool get _isOverviewTab => _isAdminMode && _currentTab == 0;
  bool get _isCashierTab => (_isAdminMode && _currentTab == 1) || (!_isAdminMode && _currentTab == 0);
  bool get _isTopUpTab => (_isAdminMode && _currentTab == 2) || (!_isAdminMode && _currentTab == 1);
  bool get _isHistoryTab => (_isAdminMode && _currentTab == 3) || (!_isAdminMode && _currentTab == 2);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    
    // Fetch merchants then dashboards
    _fetchMerchants().then((_) {
      _fetchDashboardData();
      _fetchAdminDashboardData();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final double screenWidth = MediaQuery.of(context).size.width;
      // Default to admin mode on desktop, cashier mode on mobile
      _isAdminMode = screenWidth >= 900;
      if (_isAdminMode) {
        _currentTab = 0; // Overview
        _fetchAdminDashboardData();
      } else {
        _currentTab = 0; // Cashier
      }
      _isInitialized = true;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    if (!kIsWeb) {
      NfcManager.instance.stopSession().catchError((_) {});
    }
    super.dispose();
  }

  // Formatting utility for Rupiah
  String _formatCurrency(int value) {
    String strVal = value.toString();
    String formatted = '';
    int count = 0;
    for (int i = strVal.length - 1; i >= 0; i--) {
      formatted = strVal[i] + formatted;
      count++;
      if (count == 3 && i > 0) {
        formatted = '.' + formatted;
        count = 0;
      }
    }
    return 'Rp ' + formatted;
  }

  String _formatTime(String isoString) {
    try {
      final dateTime = DateTime.parse(isoString).toLocal();
      final hour = dateTime.hour.toString().padLeft(2, '0');
      final minute = dateTime.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '12:00';
    }
  }

  // Fetches list of registered merchants from Supabase
  Future<void> _fetchMerchants() async {
    if (!widget.isSupabaseConfigured) {
      setState(() {
        _merchantsList = [
          {'id': 1, 'nama_warung': 'Warung Soto Seger', 'nama_pemilik': 'Pak Joko'},
          {'id': 2, 'nama_warung': 'Toko Souvenir Candi', 'nama_pemilik': 'Bu Sri'},
          {'id': 3, 'nama_warung': 'Kedai Kelapa Muda', 'nama_pemilik': 'Kang Asep'},
        ];
        _selectedMerchantId = 1;
      });
      return;
    }
    
    try {
      final supabase = Supabase.instance.client;
      final List<dynamic> response = await supabase
          .from('merchants')
          .select('id, nama_warung, nama_pemilik')
          .order('nama_warung', ascending: true);
          
      setState(() {
        _merchantsList = List<Map<String, dynamic>>.from(response);
        if (_merchantsList.isNotEmpty) {
          if (_selectedMerchantId == null || !_merchantsList.any((m) => m['id'] == _selectedMerchantId)) {
            _selectedMerchantId = _merchantsList[0]['id'];
          }
        }
      });
    } catch (e) {
      debugPrint('Error fetching merchants: $e');
      setState(() {
        _merchantsList = [
          {'id': 1, 'nama_warung': 'Warung Utama (Fallback)', 'nama_pemilik': 'Default'},
        ];
        _selectedMerchantId = 1;
      });
    }
  }

  // Fetches real-time transaction reports directly from Supabase for a single merchant
  Future<void> _fetchDashboardData() async {
    if (_isLoadingDashboard) return;
    
    setState(() {
      _isLoadingDashboard = true;
    });

    final int activeMerchant = _selectedMerchantId ?? 1;

    if (!widget.isSupabaseConfigured) {
      // Mock Dashboard values
      await Future.delayed(const Duration(milliseconds: 400));
      setState(() {
        _totalEarnings = 275000;
        _totalTransactionsCount = 4;
        _recentTransactions = [
          {'id': 1, 'nominal': 125000, 'created_at': DateTime.now().toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}},
          {'id': 2, 'nominal': 50000, 'created_at': DateTime.now().subtract(const Duration(minutes: 10)).toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}},
          {'id': 3, 'nominal': 15000, 'created_at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(), 'users': {'nama': 'Andi Pengunjung'}},
          {'id': 4, 'nominal': 85000, 'created_at': DateTime.now().subtract(const Duration(hours: 3)).toIso8601String(), 'users': {'nama': 'Siti Traveler'}},
        ];
        _isLoadingDashboard = false;
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch transactions list joined with user names for this merchant
      final List<dynamic> response = await supabase
          .from('transactions')
          .select('id, nominal, created_at, users(nama)')
          .eq('merchant_id', activeMerchant)
          .order('created_at', ascending: false)
          .limit(10);

      final List<Map<String, dynamic>> parsedList = List<Map<String, dynamic>>.from(response);

      // 2. Fetch sum of nominals for this merchant
      final List<dynamic> sumResponse = await supabase
          .from('transactions')
          .select('nominal')
          .eq('merchant_id', activeMerchant);
      
      int sumEarnings = 0;
      for (var row in sumResponse) {
        sumEarnings += (row['nominal'] as num).toInt();
      }

      setState(() {
        _recentTransactions = parsedList;
        _totalEarnings = sumEarnings;
        _totalTransactionsCount = sumResponse.length;
        _isLoadingDashboard = false;
      });
    } catch (e) {
      debugPrint('Error fetching dashboard stats: $e');
      setState(() {
        _isLoadingDashboard = false;
      });
    }
  }

  // Fetches global transaction statistics for the Central Admin Dashboard
  Future<void> _fetchAdminDashboardData() async {
    if (_isLoadingAdminDashboard) return;
    setState(() {
      _isLoadingAdminDashboard = true;
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(milliseconds: 500));
      setState(() {
        _totalSpendingsSum = 385000;
        _totalTopUpsSum = 785000; // Total money in system = current balances (~400k) + spendings (~385k)
        
        _allTransactionsGlobal = [
          {'id': 1, 'nominal': 15000, 'created_at': DateTime.now().toIso8601String(), 'users': {'nama': 'Andi Pengunjung'}, 'merchants': {'nama_warung': 'Warung Soto Seger'}},
          {'id': 2, 'nominal': 50000, 'created_at': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}, 'merchants': {'nama_warung': 'Toko Souvenir Candi'}},
          {'id': 3, 'nominal': 120000, 'created_at': DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String(), 'users': {'nama': 'Siti Traveler'}, 'merchants': {'nama_warung': 'Kedai Kelapa Muda'}},
          {'id': 4, 'nominal': 200000, 'created_at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}, 'merchants': {'nama_warung': 'Warung Soto Seger'}},
        ];
        
        _bestSellingMerchants = [
          {'nama_warung': 'Warung Soto Seger', 'total_omzet': 215000},
          {'nama_warung': 'Kedai Kelapa Muda', 'total_omzet': 120000},
          {'nama_warung': 'Toko Souvenir Candi', 'total_omzet': 50000},
        ];
        _isLoadingAdminDashboard = false;
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch sum of balances of all users
      final usersResponse = await supabase.from('users').select('saldo');
      int sumBalances = 0;
      for (var u in usersResponse) {
        sumBalances += (u['saldo'] as num?)?.toInt() ?? 0;
      }

      // 2. Fetch all transactions for calculations
      final txResponse = await supabase
          .from('transactions')
          .select('id, nominal, created_at, users(nama), merchants(nama_warung)')
          .order('created_at', ascending: false);

      final List<Map<String, dynamic>> allTx = List<Map<String, dynamic>>.from(txResponse);

      int sumSpendings = 0;
      Map<String, int> merchantSales = {};
      
      // Initialize map with all registered merchants to show 0 if no sales
      for (var m in _merchantsList) {
        String name = m['nama_warung'] ?? 'Warung';
        merchantSales[name] = 0;
      }

      for (var tx in allTx) {
        final nominal = (tx['nominal'] as num?)?.toInt() ?? 0;
        sumSpendings += nominal;
        
        final merchantName = tx['merchants']?['nama_warung'] ?? 'Warung Umum';
        merchantSales[merchantName] = (merchantSales[merchantName] ?? 0) + nominal;
      }

      // Format ranked merchants
      final rankedMerchantsList = merchantSales.entries
          .map((e) => {'nama_warung': e.key, 'total_omzet': e.value})
          .toList()
        ..sort((a, b) => (b['total_omzet'] as int).compareTo(a['total_omzet'] as int));

      setState(() {
        _totalSpendingsSum = sumSpendings;
        _totalTopUpsSum = sumBalances + sumSpendings;
        _allTransactionsGlobal = allTx;
        _bestSellingMerchants = rankedMerchantsList;
        _isLoadingAdminDashboard = false;
      });
    } catch (e) {
      debugPrint('Error fetching admin dashboard: $e');
      setState(() {
        _isLoadingAdminDashboard = false;
      });
    }
  }

  // Keypad Tap handlers based on the active tab
  void _handleKeypadTap(String value) {
    if (_currentStatus != TransactionStatus.waitingForInput &&
        _currentStatus != TransactionStatus.success &&
        _currentStatus != TransactionStatus.failed) {
      return; // Lock input during execution
    }

    if (_currentStatus == TransactionStatus.success || _currentStatus == TransactionStatus.failed) {
      _resetTransaction();
    }

    setState(() {
      int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;

      if (value == 'C') {
        activeAmount = 0;
      } else if (value == '⌫') {
        String currentStr = activeAmount.toString();
        if (currentStr.length > 1) {
          activeAmount = int.parse(currentStr.substring(0, currentStr.length - 1));
        } else {
          activeAmount = 0;
        }
      } else if (value == '00') {
        if (activeAmount > 0 && activeAmount < 10000000) {
          activeAmount = activeAmount * 100;
        }
      } else {
        String currentStr = activeAmount == 0 ? '' : activeAmount.toString();
        if (currentStr.length < 9) {
          activeAmount = int.parse(currentStr + value);
        }
      }

      if (_isCashierTab) {
        _cashierAmount = activeAmount;
        _statusMessage = _cashierAmount > 0 
            ? 'Siap diproses: ${_formatCurrency(_cashierAmount)}' 
            : 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _topUpAmount = activeAmount;
        _statusMessage = _topUpAmount > 0 
            ? 'Siap top-up: ${_formatCurrency(_topUpAmount)}' 
            : 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
  }

  void _addQuickAmount(int amount) {
    if (_currentStatus != TransactionStatus.waitingForInput && 
        _currentStatus == TransactionStatus.processing) {
      return;
    }
    
    if (_currentStatus == TransactionStatus.success || _currentStatus == TransactionStatus.failed) {
      _resetTransaction();
    }

    setState(() {
      if (_isCashierTab) {
        _cashierAmount += amount;
        _statusMessage = 'Siap diproses: ${_formatCurrency(_cashierAmount)}';
      } else {
        _topUpAmount += amount;
        _statusMessage = 'Siap top-up: ${_formatCurrency(_topUpAmount)}';
      }
    });
  }

  void _clearAmount() {
    setState(() {
      if (_isCashierTab) {
        _cashierAmount = 0;
        _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _topUpAmount = 0;
        _statusMessage = 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
  }

  void _resetTransaction() {
    if (!kIsWeb) {
      NfcManager.instance.stopSession().catchError((_) {});
    }
    setState(() {
      _cashierAmount = 0;
      _topUpAmount = 0;
      nfcUid = null;
      remainingSaldo = null;
      loadedNewSaldo = null;
      touristName = null;
      _currentStatus = TransactionStatus.waitingForInput;
      if (_isCashierTab) {
        _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _statusMessage = 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
    _fetchDashboardData();
    _fetchAdminDashboardData();
  }

  // Deduct balance logic (Tab 0)
  Future<void> prosesPotongSaldo(String uid, int nominal) async {
    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Memproses pemotongan saldo...';
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(seconds: 2));
      if (uid == '00:00:00:00') {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Souvenir Tidak Terdaftar!';
        });
        return;
      }
      
      int mockUserSaldo = 150000;
      if (mockUserSaldo < nominal) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Saldo Wisatawan Tidak Cukup!';
        });
        return;
      }
      
      setState(() {
        touristName = 'Budi Wisatawan';
        remainingSaldo = mockUserSaldo - nominal;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Pembayaran Berhasil!';
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch user by nfc_uid
      final userData = await supabase
          .from('users')
          .select('id, saldo, nama')
          .eq('nfc_uid', uid)
          .maybeSingle();

      if (userData == null) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Souvenir Tidak Terdaftar!';
        });
        return;
      }

      final userId = userData['id'];
      final int currentSaldo = userData['saldo'] ?? 0;
      final String name = userData['nama'];

      // 2. Check balance
      if (currentSaldo < nominal) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Saldo Wisatawan Tidak Cukup!';
        });
        return;
      }

      // 3. Update balance
      final int newSaldo = currentSaldo - nominal;
      await supabase
          .from('users')
          .update({'saldo': newSaldo})
          .eq('id', userId);

      // 4. Record transaction log
      await supabase.from('transactions').insert({
        'user_id': userId,
        'merchant_id': _selectedMerchantId ?? 1,
        'nominal': nominal,
        'created_at': DateTime.now().toIso8601String(),
      });

      setState(() {
        touristName = name;
        remainingSaldo = newSaldo;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Pembayaran Berhasil!';
      });

      if (!kIsWeb) {
        await NfcManager.instance.stopSession().catchError((_) {});
      }
    } catch (e) {
      debugPrint('Deduct balance transaction error: $e');
      setState(() {
        _currentStatus = TransactionStatus.failed;
        _statusMessage = 'Error: Gagal memproses transaksi ($e)';
      });
    }
  }

  // Top-Up balance logic (Tab 1)
  Future<void> prosesTopUpSaldo(String uid, int nominal) async {
    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Memproses penambahan saldo...';
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(seconds: 2));
      setState(() {
        touristName = 'Budi Wisatawan';
        loadedNewSaldo = 150000 + nominal;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Top-Up Berhasil!';
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Check if user already exists
      final userData = await supabase
          .from('users')
          .select('id, saldo, nama')
          .eq('nfc_uid', uid)
          .maybeSingle();

      if (userData != null) {
        final userId = userData['id'];
        final int currentSaldo = userData['saldo'] ?? 0;
        final String name = userData['nama'];
        final int newSaldo = currentSaldo + nominal;

        await supabase
            .from('users')
            .update({'saldo': newSaldo})
            .eq('id', userId);

        setState(() {
          touristName = name;
          loadedNewSaldo = newSaldo;
          _currentStatus = TransactionStatus.success;
          _statusMessage = 'Top-Up Berhasil!';
        });
      } else {
        // Option B: New card scanned! Auto-register as a new tourist
        String newTouristName = 'Wisatawan #${uid.substring(uid.length - 5).replaceAll(':', '')}';
        
        await supabase.from('users').insert({
          'nama': newTouristName,
          'nfc_uid': uid,
          'saldo': nominal,
          'created_at': DateTime.now().toIso8601String(),
        });

        setState(() {
          touristName = newTouristName;
          loadedNewSaldo = nominal;
          _currentStatus = TransactionStatus.success;
          _statusMessage = 'Pendaftaran & Top-Up Berhasil!';
        });
      }

      if (!kIsWeb) {
        await NfcManager.instance.stopSession().catchError((_) {});
      }
    } catch (e) {
      debugPrint('Top Up Supabase transaction error: $e');
      setState(() {
        _currentStatus = TransactionStatus.failed;
        _statusMessage = 'Error: Gagal melakukan pengisian ($e)';
      });
    }
  }

  // NFC Session Initiations
  Future<void> _startPaymentProcess() async {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    if (activeAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isCashierTab ? 'Nominal belanja tidak boleh kosong!' : 'Nominal top-up tidak boleh kosong!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() {
      _currentStatus = TransactionStatus.waitingForCard;
      _statusMessage = _isCashierTab
          ? 'Silahkan tempel souvenir RFID ke belakang HP...'
          : 'Tempelkan souvenir RFID untuk menambahkan saldo...';
      nfcUid = null;
      remainingSaldo = null;
      loadedNewSaldo = null;
      touristName = null;
    });

    if (kIsWeb) return; // Uses visual card tap simulator in Chrome

    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sensor NFC tidak didukung pada perangkat ini. Gunakan simulator di layar untuk menguji.'),
          backgroundColor: Colors.amber,
          duration: Duration(seconds: 4),
        ),
      );
    }

    try {
      await NfcManager.instance.startSession(
        onDiscovered: (NfcTag tag) async {
          final idBytes = _getNfcId(tag);
          if (idBytes != null) {
            final String formattedUid = _toHexString(idBytes);
            setState(() {
              nfcUid = formattedUid;
            });
            HapticFeedback.vibrate();
            await NfcManager.instance.stopSession();
            
            if (_isCashierTab) {
              await prosesPotongSaldo(formattedUid, _cashierAmount);
            } else {
              await prosesTopUpSaldo(formattedUid, _topUpAmount);
            }
          } else {
            setState(() {
              _statusMessage = 'RFID terdeteksi, tetapi UID tidak terbaca.';
            });
            await NfcManager.instance.stopSession(errorMessage: 'Gagal membaca UID.');
          }
        },
        onError: (error) async {
          setState(() {
            _currentStatus = TransactionStatus.failed;
            _statusMessage = 'NFC Error: ${error.message}';
          });
        }
      );
    } catch (e) {
      debugPrint('Error starting NFC Session: $e');
    }
  }

  Future<void> _simulateCardTap() async {
    if (_currentStatus != TransactionStatus.waitingForCard) return;

    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Membaca data chip RFID...';
    });

    await Future.delayed(const Duration(seconds: 1));
    const String mockUid = '04:A2:B3:C4';

    setState(() {
      nfcUid = mockUid;
    });

    HapticFeedback.vibrate();
    
    if (_isCashierTab) {
      await prosesPotongSaldo(mockUid, _cashierAmount);
    } else {
      await prosesTopUpSaldo(mockUid, _topUpAmount);
    }
  }

  // Security Access Management (PIN)
  void _showPINDialog() {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF151D30),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: Color(0xFF6366F1)),
              SizedBox(width: 10),
              Text('Mode Pengelola', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Masukkan PIN Keamanan Pusat:', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 12),
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF6366F1))),
                  counterText: '',
                  hintText: 'PIN (Default: 2026)',
                ),
                style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 8),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                if (pinController.text == '2026') {
                  Navigator.pop(context);
                  setState(() {
                    _isAdminMode = true;
                    _currentTab = 0; // Default to Admin Overview
                    _resetTransaction();
                  });
                  _fetchAdminDashboardData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Selamat Datang, Pengelola Pusat!'), backgroundColor: Colors.green),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN Salah! Akses Ditolak.'), backgroundColor: Colors.redAccent),
                  );
                }
              },
              child: const Text('Masuk'),
            ),
          ],
        );
      },
    );
  }

  void _exitAdminMode() {
    setState(() {
      _isAdminMode = false;
      _currentTab = 0; // Default to Cashier Belanja
      _resetTransaction();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Keluar dari Mode Pengelola.'), backgroundColor: Colors.blueGrey),
    );
  }

  // UI Build methods
  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= 900;

    return Scaffold(
      body: Row(
        children: [
          // Premium Left Navigation Sidebar (Desktop only)
          if (isDesktop) _buildDesktopNavSidebar(),

          // Center POS Input Column (Or Full Admin Dashboard)
          Expanded(
            flex: isDesktop ? ( (_isOverviewTab || _isHistoryTab) ? 12 : 6 ) : 1,
            child: Container(
              color: const Color(0xFF0E1322), // Deep Navy Slate
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPOSHeader(),
                      const SizedBox(height: 12),
                      
                      // Active dropdown for merchants in cashier mode
                      _buildMerchantSelector(),
                      
                      _isHistoryTab || _isOverviewTab 
                          ? const SizedBox.shrink() 
                          : _buildLEDAmountDisplay(),
                      const SizedBox(height: 14),
                      
                      _isHistoryTab || _isOverviewTab 
                          ? const SizedBox.shrink() 
                          : _buildQuickAmountSelector(),
                      const SizedBox(height: 16),
                      
                      Expanded(
                        child: _isOverviewTab
                            ? _buildAdminOverviewView()
                            : (_isHistoryTab 
                                ? (_isAdminMode ? _buildGlobalHistoryView() : _buildDashboardView()) 
                                : _buildDigitalKeypad()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          // Right POS Terminal Column (Payment Status & NFC wireless animations - Desktop only)
          if (isDesktop && !_isOverviewTab && !_isHistoryTab)
            Expanded(
              flex: 5,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF080B13), // Deep Obsidian black
                  border: Border(
                    left: BorderSide(color: Color(0xFF1E293B), width: 1.5),
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: _buildTerminalConsole(),
                  ),
                ),
              ),
            ),
        ],
      ),
      // Mobile Bottom Sheets & Navigation Bar
      bottomNavigationBar: !isDesktop ? _buildMobileNavBar() : null,
      bottomSheet: !isDesktop && _currentStatus != TransactionStatus.waitingForInput && !_isOverviewTab && !_isHistoryTab
          ? _buildMobileTerminalOverlay()
          : null,
    );
  }

  // Sidebar navigation panel for desktop POS Terminal
  Widget _buildDesktopNavSidebar() {
    return Container(
      width: 240,
      color: const Color(0xFF080B13), // Deep Obsidian black
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand Logo
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF818CF8), size: 20),
              ),
              const SizedBox(width: 10),
              const Text(
                'E-WISATA PAY',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _isAdminMode ? '🛡️ MODE PUSAT (ADMIN)' : '🏪 MODE KASIR WARUNG',
            style: TextStyle(fontSize: 10, color: _isAdminMode ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold, letterSpacing: 1.0),
          ),
          const SizedBox(height: 36),
          
          // Menu Items
          if (_isAdminMode) ...[
            _buildSidebarNavItem(0, Icons.analytics_rounded, 'Overview Pusat'),
            const SizedBox(height: 12),
            _buildSidebarNavItem(1, Icons.point_of_sale_rounded, 'Kasir Belanja'),
            const SizedBox(height: 12),
            _buildSidebarNavItem(2, Icons.add_card_rounded, 'Top-Up Saldo'),
            const SizedBox(height: 12),
            _buildSidebarNavItem(3, Icons.list_alt_rounded, 'Riwayat Global'),
          ] else ...[
            _buildSidebarNavItem(0, Icons.point_of_sale_rounded, 'Kasir Belanja'),
            const SizedBox(height: 12),
            _buildSidebarNavItem(1, Icons.add_card_rounded, 'Top-Up Saldo'),
            const SizedBox(height: 12),
            _buildSidebarNavItem(2, Icons.history_rounded, 'Riwayat Warung'),
          ],
          
          const Spacer(),

          // Admin Access Toggle
          InkWell(
            onTap: _isAdminMode ? _exitAdminMode : _showPINDialog,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: _isAdminMode ? Colors.redAccent.withOpacity(0.12) : const Color(0xFF1E293B).withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isAdminMode ? Colors.redAccent.withOpacity(0.3) : const Color(0xFF1E293B),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isAdminMode ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                    color: _isAdminMode ? Colors.redAccent : Colors.grey,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isAdminMode ? 'Keluar Admin' : 'Masuk Admin',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isAdminMode ? Colors.redAccent : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Supabase Status
          _buildOnlineStatusBadge(),
        ],
      ),
    );
  }

  Widget _buildOnlineStatusBadge() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151C2C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.isSupabaseConfigured ? Colors.green : Colors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.isSupabaseConfigured ? 'Database Online' : 'Sandbox Offline',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.isSupabaseConfigured 
                ? 'Sinkronisasi cloud aktif.' 
                : 'Data hanya disimpan lokal.',
            style: TextStyle(fontSize: 9, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarNavItem(int index, IconData icon, String label) {
    final bool isSelected = _currentTab == index;
    return InkWell(
      onTap: () {
        setState(() {
          _currentTab = index;
          _resetTransaction();
        });
        if (_isAdminMode && index == 0) {
          _fetchAdminDashboardData();
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1).withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected 
              ? Border.all(color: const Color(0xFF6366F1).withOpacity(0.4)) 
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF818CF8) : Colors.grey, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPOSHeader() {
    String titleText = '';
    if (_isOverviewTab) {
      titleText = '📊 MONITORING PUSAT';
    } else if (_isCashierTab) {
      titleText = '🛒 TERMINAL KASIR BELANJA';
    } else if (_isTopUpTab) {
      titleText = '💳 PENGISIAN SALDO WISATA';
    } else if (_isHistoryTab) {
      titleText = _isAdminMode ? '📋 RIWAYAT TRANSAKSI GLOBAL' : '📋 LAPORAN KASIR HARIAN';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            titleText,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.1),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mode Toggle Icon for Mobile
            if (MediaQuery.of(context).size.width < 900)
              IconButton(
                icon: Icon(
                  _isAdminMode ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                  color: _isAdminMode ? Colors.redAccent : Colors.grey,
                  size: 20,
                ),
                onPressed: _isAdminMode ? _exitAdminMode : _showPINDialog,
                tooltip: _isAdminMode ? 'Keluar Admin' : 'Masuk Admin',
              ),
            if ((_isCashierTab && _cashierAmount > 0) || (_isTopUpTab && _topUpAmount > 0))
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.grey),
                onPressed: _clearAmount,
                tooltip: 'Clear nominal',
              )
          ],
        )
      ],
    );
  }

  Widget _buildMerchantSelector() {
    if (!_isCashierTab || _merchantsList.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF151C2C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _selectedMerchantId,
          dropdownColor: const Color(0xFF151C2C),
          icon: const Icon(Icons.storefront_rounded, color: Color(0xFF818CF8)),
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          onChanged: (int? newValue) {
            setState(() {
              _selectedMerchantId = newValue;
            });
            _fetchDashboardData();
          },
          items: _merchantsList.map<DropdownMenuItem<int>>((Map<String, dynamic> merchant) {
            return DropdownMenuItem<int>(
              value: merchant['id'] as int,
              child: Text(merchant['nama_warung'] ?? 'Warung'),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildLEDAmountDisplay() {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF151C2C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E293B), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _isCashierTab ? 'NOMINAL DEBIT BELANJA' : 'NOMINAL TOP-UP SALDO',
                style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.1),
              ),
              const Text(
                'IDR',
                style: TextStyle(fontSize: 10, color: Color(0xFF818CF8), fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _formatCurrency(activeAmount),
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w900,
                color: activeAmount == 0 ? const Color(0xFF334155) : const Color(0xFF818CF8),
                shadows: activeAmount == 0
                    ? null
                    : [Shadow(color: const Color(0xFF6366F1).withOpacity(0.4), blurRadius: 15)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAmountSelector() {
    final values = _isCashierTab ? [10000, 25000, 50000, 100000] : [20000, 50000, 100000, 200000];
    final isEnabled = _currentStatus == TransactionStatus.waitingForInput;

    return Row(
      children: values.map((val) {
        String text = '+${val ~/ 1000}k';
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: InkWell(
              onTap: isEnabled ? () => _addQuickAmount(val) : null,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isEnabled 
                      ? const Color(0xFF1E293B).withOpacity(0.4) 
                      : Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isEnabled ? const Color(0xFF1E293B) : Colors.transparent,
                  ),
                ),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isEnabled ? Colors.white : Colors.grey[600],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDigitalKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '⌫'],
    ];

    return Column(
      children: [
        Expanded(
          child: Column(
            children: keys.map((row) {
              return Expanded(
                child: Row(
                  children: row.map((key) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: _buildKeypadButton(key),
                      ),
                    );
                  }).toList(),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
        _buildKeypadActionButton(),
      ],
    );
  }

  Widget _buildKeypadActionButton() {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    final bool canClick = activeAmount > 0 && _currentStatus == TransactionStatus.waitingForInput;
    
    return Container(
      height: 52,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: canClick 
            ? LinearGradient(
                colors: _isCashierTab 
                    ? [const Color(0xFF6366F1), const Color(0xFF8B5CF6)] 
                    : [const Color(0xFF10B981), const Color(0xFF059669)],
              ) 
            : null,
        color: canClick ? null : const Color(0xFF151C2C),
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: canClick ? _startPaymentProcess : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isCashierTab ? Icons.nfc_rounded : Icons.add_card_rounded, 
              color: canClick ? Colors.white : Colors.grey[600],
              size: 20,
            ),
            const SizedBox(width: 10),
            Text(
              _isCashierTab ? 'PROSES PEMBAYARAN' : 'PROSES TOP-UP SALDO',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: canClick ? Colors.white : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTerminalConsole() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _isCashierTab ? 'MESIN PEMOTONG SALDO' : 'MESIN PENGISI SALDO',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12, 
            fontWeight: FontWeight.bold, 
            color: _isCashierTab ? const Color(0xFF818CF8) : const Color(0xFF34D399),
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F1424),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFF1E293B), width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                children: [
                  _buildAnimatedNFCBackground(),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: _buildTerminalStateBody(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTerminalStateBody() {
    switch (_currentStatus) {
      case TransactionStatus.waitingForInput:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isCashierTab ? Icons.point_of_sale_rounded : Icons.add_card_rounded, 
              size: 70, 
              color: Colors.grey[850],
            ),
            const SizedBox(height: 20),
            Text(
              _isCashierTab ? 'Kasir Belanja Idle' : 'Top-Up Terminal Idle',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _isCashierTab 
                  ? 'Ketik nominal belanja lalu tekan "Proses Pembayaran".' 
                  : 'Ketik nominal top-up lalu tekan "Proses Top-Up".',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        );
        
      case TransactionStatus.waitingForCard:
      case TransactionStatus.processing:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            CircleAvatar(
              radius: 36,
              backgroundColor: (_isCashierTab ? const Color(0xFF6366F1) : const Color(0xFF10B981)).withOpacity(0.15),
              child: Icon(
                _isCashierTab ? Icons.nfc_rounded : Icons.contactless_rounded, 
                size: 40, 
                color: _isCashierTab ? const Color(0xFF818CF8) : const Color(0xFF34D399),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _currentStatus == TransactionStatus.processing 
                  ? 'Membaca data kartu...' 
                  : (_isCashierTab ? 'Siap Potong Saldo' : 'Siap Top-Up Saldo'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
            const Spacer(),
            _buildInteractiveCardSimulator(),
          ],
        );

      case TransactionStatus.success:
        return _isCashierTab ? _buildHolographicReceipt() : _buildTopUpHolographicReceipt();

      case TransactionStatus.failed:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline_rounded, size: 40, color: Colors.redAccent),
            ),
            const SizedBox(height: 20),
            const Text(
              'Transaksi Gagal',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.redAccent),
            ),
            const SizedBox(height: 6),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startPaymentProcess,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('Coba Lagi'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E293B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _resetTransaction,
              child: const Text('Batal & Reset', style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
          ],
        );
    }
  }

  Widget _buildTopUpHolographicReceipt() {
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add_task_rounded, size: 44, color: Colors.greenAccent),
          ),
          const SizedBox(height: 14),
          const Text(
            'Top-Up Saldo Sukses!',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.greenAccent),
          ),
          const SizedBox(height: 16),
          
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withOpacity(0.4),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              children: [
                _buildReceiptRow('Wisatawan', touristName ?? 'N/A', isBold: true),
                const Divider(height: 20, thickness: 1, color: Colors.white10),
                _buildReceiptRow('Jumlah Top-Up', _formatCurrency(_topUpAmount), isGreen: true),
                const SizedBox(height: 8),
                _buildReceiptRow('Nomor Chip UID', nfcUid ?? 'N/A'),
                const SizedBox(height: 8),
                _buildReceiptRow('Loket Pengisian', 'Loket Utama Zone A'),
                const SizedBox(height: 8),
                _buildReceiptRow('Saldo Akhir', loadedNewSaldo != null ? _formatCurrency(loadedNewSaldo!) : 'N/A', isBold: true),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _resetTransaction,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Top-Up Baru', style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  Widget _buildHolographicReceipt() {
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_rounded, size: 44, color: Colors.greenAccent),
          ),
          const SizedBox(height: 14),
          const Text(
            'Pembayaran Sukses!',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.greenAccent),
          ),
          const SizedBox(height: 16),
          
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withOpacity(0.4),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              children: [
                _buildReceiptRow('Wisatawan', touristName ?? 'Wisatawan', isBold: true),
                const Divider(height: 20, thickness: 1, color: Colors.white10),
                _buildReceiptRow('Nominal Belanja', _formatCurrency(_cashierAmount), isBold: true),
                const SizedBox(height: 8),
                _buildReceiptRow('Tipe Pembayaran', 'RFID Cashless Token'),
                const SizedBox(height: 8),
                _buildReceiptRow('UID Kartu', nfcUid ?? 'N/A'),
                const SizedBox(height: 8),
                _buildReceiptRow('Loket Kasir', _merchantsList.firstWhere((m) => m['id'] == _selectedMerchantId, orElse: () => {'nama_warung': 'Loket Kasir'})['nama_warung']),
                const SizedBox(height: 8),
                _buildReceiptRow('Sisa Saldo', remainingSaldo != null ? _formatCurrency(remainingSaldo!) : 'N/A', isGreen: true),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _resetTransaction,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Transaksi Baru', style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value, {bool isBold = false, bool isGreen = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isGreen 
                ? Colors.greenAccent 
                : (isBold ? Colors.white : Colors.grey[200]),
          ),
        ),
      ],
    );
  }

  Widget _buildInteractiveCardSimulator() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.amber, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text(
                'SIMULATOR CHIP RFID',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          Container(
            height: 80,
            width: 150,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isCashierTab
                    ? [const Color(0xFFEC4899), const Color(0xFF8B5CF6)]
                    : [const Color(0xFF34D399), const Color(0xFF059669)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: (_isCashierTab ? const Color(0xFFEC4899) : const Color(0xFF34D399)).withOpacity(0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 16,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.amber[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 14),
                    ],
                  ),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'E-WISATA CARD',
                        style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.0),
                      ),
                      Text(
                        'Balanced Cashless',
                        style: TextStyle(fontSize: 6, color: Colors.white70),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _simulateCardTap,
            icon: const Icon(Icons.touch_app_rounded, size: 14),
            label: const Text('Simulasikan Tap Kartu', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              elevation: 0,
            ),
          )
        ],
      ),
    );
  }

  // Left Column Dashboard reporting view (Merchant history tab)
  Widget _buildDashboardView() {
    return _isLoadingDashboard 
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'REKAP KEUANGAN WARUNG',
                    style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.indigoAccent),
                    onPressed: _fetchDashboardData,
                    tooltip: 'Refresh Laporan',
                  )
                ],
              ),
              const SizedBox(height: 10),
              
              // Stats Card 1: Total Earnings
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E1E38), Color(0xFF13132B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF312E81).withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('PENDAPATAN WARUNG HARI INI', style: TextStyle(fontSize: 10, color: Colors.grey, letterSpacing: 1.0)),
                    const SizedBox(height: 6),
                    Text(
                      _formatCurrency(_totalEarnings),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF34D399)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              
              // Stats Card 2: Transactions Count
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF151C2C),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF1E293B)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TRANSAKSI BERHASIL', style: TextStyle(fontSize: 9, color: Colors.grey, letterSpacing: 1.0)),
                        SizedBox(height: 4),
                        Text('Jumlah struk terbit', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    Text(
                      '$_totalTransactionsCount Kali',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
              
              // Show recent transactions inside left column if on Mobile
              if (MediaQuery.of(context).size.width < 900) ...[
                const SizedBox(height: 24),
                const Text(
                  '10 TRANSAKSI TERAKHIR',
                  style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                const SizedBox(height: 8),
                Expanded(child: _buildTransactionsListViewWidget()),
              ],
            ],
          );
  }

  // Right column Dashboard Transactions List (Desktop only)
  Widget _buildDashboardRecentTransactionsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '10 TRANSAKSI TERAKHIR (REAL-TIME)',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12, 
            fontWeight: FontWeight.bold, 
            color: Color(0xFF818CF8),
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1424),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF1E293B), width: 1.5),
            ),
            child: _buildTransactionsListViewWidget(),
          ),
        ),
      ],
    );
  }

  // Reusable transactions list widget
  Widget _buildTransactionsListViewWidget() {
    if (_recentTransactions.isEmpty) {
      return Center(
        child: Text(
          'Belum ada transaksi hari ini.',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      itemCount: _recentTransactions.length,
      itemBuilder: (context, index) {
        final tx = _recentTransactions[index];
        final String name = tx['users'] != null ? tx['users']['nama'] : 'Wisatawan';
        final int nominal = tx['nominal'] ?? 0;
        final String time = _formatTime(tx['created_at']);

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B).withOpacity(0.3),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF1E293B).withOpacity(0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFF10B981).withOpacity(0.15),
                    child: const Icon(Icons.arrow_downward_rounded, size: 18, color: Color(0xFF34D399)),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text('Merchant Aktif • $time WIB', style: TextStyle(fontSize: 9, color: Colors.grey[500])),
                    ],
                  ),
                ],
              ),
              Text(
                '+ ${_formatCurrency(nominal)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF34D399)),
              ),
            ],
          ),
        );
      },
    );
  }

  // Central Manager Dashboard UI View
  Widget _buildAdminOverviewView() {
    return _isLoadingAdminDashboard
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _fetchAdminDashboardData,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'MONITORING KEUANGAN PUSAT',
                        style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, color: Colors.indigoAccent),
                        onPressed: () {
                          _fetchMerchants();
                          _fetchAdminDashboardData();
                        },
                        tooltip: 'Refresh Dashboard',
                      )
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Financial Summary Cards
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final bool isWide = constraints.maxWidth > 700;
                      return isWide 
                          ? Row(
                              children: [
                                Expanded(child: _buildOverviewCard('TOTAL UANG MASUK (TOP-UP)', _totalTopUpsSum, const Color(0xFF6366F1))),
                                const SizedBox(width: 12),
                                Expanded(child: _buildOverviewCard('TOTAL BELANJA (REALISASI)', _totalSpendingsSum, const Color(0xFF10B981))),
                                const SizedBox(width: 12),
                                Expanded(child: _buildOverviewCard('SALDO BEREDAR (OUTSTANDING)', _totalTopUpsSum - _totalSpendingsSum, const Color(0xFFF59E0B))),
                              ],
                            )
                          : Column(
                              children: [
                                _buildOverviewCard('TOTAL UANG MASUK (TOP-UP)', _totalTopUpsSum, const Color(0xFF6366F1)),
                                const SizedBox(height: 10),
                                _buildOverviewCard('TOTAL BELANJA (REALISASI)', _totalSpendingsSum, const Color(0xFF10B981)),
                                const SizedBox(height: 10),
                                _buildOverviewCard('SALDO BEREDAR (OUTSTANDING)', _totalTopUpsSum - _totalSpendingsSum, const Color(0xFFF59E0B)),
                              ],
                            );
                    },
                  ),
                  const SizedBox(height: 24),

                  // Two columns ranking vs live logs
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final bool isWide = constraints.maxWidth > 800;
                      return isWide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _buildDashboardSection('Peringkat Warung Terlaris', _buildBestSellingMerchantsList()),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  flex: 6,
                                  child: _buildDashboardSection('Log Transaksi Tempat Wisata (Global)', _buildGlobalLiveTransactionsTable()),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                _buildDashboardSection('Peringkat Warung Terlaris', _buildBestSellingMerchantsList()),
                                const SizedBox(height: 20),
                                _buildDashboardSection('Log Transaksi Tempat Wisata (Global)', _buildGlobalLiveTransactionsTable()),
                              ],
                            );
                    },
                  ),
                ],
              ),
            ),
          );
  }

  Widget _buildOverviewCard(String title, int amount, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF151C2C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _formatCurrency(amount),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: color,
                shadows: [
                  Shadow(color: color.withOpacity(0.2), blurRadius: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardSection(String title, Widget content) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111726),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF818CF8), letterSpacing: 1.2),
          ),
          const SizedBox(height: 16),
          content,
        ],
      ),
    );
  }

  Widget _buildBestSellingMerchantsList() {
    if (_bestSellingMerchants.isEmpty) {
      return const Center(child: Text('Belum ada data penjualan warung.', style: TextStyle(color: Colors.grey)));
    }
    
    // Find max revenue for proportion calculation
    int maxRevenue = 1;
    for (var m in _bestSellingMerchants) {
      int rev = m['total_omzet'] as int;
      if (rev > maxRevenue) maxRevenue = rev;
    }
    
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _bestSellingMerchants.length,
      itemBuilder: (context, index) {
        final m = _bestSellingMerchants[index];
        final String name = m['nama_warung'] ?? 'Warung';
        final int omzet = m['total_omzet'] ?? 0;
        final double proportion = omzet / maxRevenue;
        
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '#${index + 1} $name',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  Text(
                    _formatCurrency(omzet),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF34D399)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Stack(
                children: [
                  Container(
                    height: 8,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  FractionallySizedBox(
                     widthFactor: proportion.clamp(0.001, 1.0),
                     child: Container(
                       height: 8,
                       decoration: BoxDecoration(
                         gradient: const LinearGradient(
                           colors: [Color(0xFF6366F1), Color(0xFFEC4899)],
                         ),
                         borderRadius: BorderRadius.circular(4),
                         boxShadow: [
                           BoxShadow(
                             color: const Color(0xFF6366F1).withOpacity(0.4),
                             blurRadius: 4,
                           ),
                         ],
                       ),
                     ),
                   ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalLiveTransactionsTable() {
    if (_allTransactionsGlobal.isEmpty) {
      return const Center(child: Text('Belum ada transaksi di tempat wisata.', style: TextStyle(color: Colors.grey)));
    }
    
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _allTransactionsGlobal.length > 15 ? 15 : _allTransactionsGlobal.length,
      itemBuilder: (context, index) {
        final tx = _allTransactionsGlobal[index];
        final String userName = tx['users'] != null ? tx['users']['nama'] : 'Wisatawan';
        final String merchantName = tx['merchants'] != null ? tx['merchants']['nama_warung'] : 'Warung Umum';
        final int nominal = tx['nominal'] ?? 0;
        final String time = _formatTime(tx['created_at']);
        
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B).withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1E293B).withOpacity(0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(userName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 2),
                    Text('Membeli di: $merchantName • $time WIB', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  ],
                ),
              ),
              Text(
                _formatCurrency(nominal),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF34D399)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalHistoryView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'RIWAYAT SELURUH TRANSAKSI KASIR',
          style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1424),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: _buildGlobalLiveTransactionsTable(),
          ),
        ),
      ],
    );
  }

  // Mobile navigation & overlays
  Widget _buildMobileNavBar() {
    return NavigationBar(
      selectedIndex: _currentTab,
      onDestinationSelected: (index) {
        setState(() {
          _currentTab = index;
          _resetTransaction();
        });
        if (_isAdminMode && index == 0) {
          _fetchAdminDashboardData();
        }
      },
      backgroundColor: const Color(0xFF080B13),
      indicatorColor: const Color(0xFF6366F1).withOpacity(0.15),
      destinations: _isAdminMode
          ? const [
              NavigationDestination(icon: Icon(Icons.analytics_rounded), label: 'Overview'),
              NavigationDestination(icon: Icon(Icons.point_of_sale_rounded), label: 'Kasir'),
              NavigationDestination(icon: Icon(Icons.add_card_rounded), label: 'Top-Up'),
              NavigationDestination(icon: Icon(Icons.list_alt_rounded), label: 'Riwayat'),
            ]
          : const [
              NavigationDestination(icon: Icon(Icons.point_of_sale_rounded), label: 'Kasir'),
              NavigationDestination(icon: Icon(Icons.add_card_rounded), label: 'Top-Up'),
              NavigationDestination(icon: Icon(Icons.analytics_rounded), label: 'Riwayat'),
            ],
    );
  }

  Widget _buildMobileTerminalOverlay() {
    return Container(
      height: 350,
      decoration: const BoxDecoration(
        color: Color(0xFF0F1424),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0xFF1E293B), width: 1.5)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Stack(
          children: [
            _buildAnimatedNFCBackground(),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: _buildTerminalStateBody(),
            ),
          ],
        ),
      ),
    );
  }

  // NFC UID readers
  List<int>? _getNfcId(NfcTag tag) {
    final Map<String, dynamic> data = tag.data;
    final List<dynamic>? identifier = data['nfca']?['identifier'] ??
        data['nfcb']?['identifier'] ??
        data['nfcf']?['identifier'] ??
        data['nfcv']?['identifier'] ??
        data['isodep']?['identifier'] ??
        data['mifareclassic']?['identifier'] ??
        data['mifareultralight']?['identifier'];
    return identifier?.cast<int>();
  }

  String _toHexString(List<int> bytes) {
    return bytes.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
  }

  Widget _buildKeypadButton(String key) {
    final isEnabled = _currentStatus == TransactionStatus.waitingForInput;
    final isSpecial = key == 'C' || key == '⌫';
    
    Color textColor = Colors.white;
    if (isSpecial) {
      textColor = key == 'C' ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
    }
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEnabled ? () => _handleKeypadTap(key) : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: isEnabled 
                ? const Color(0xFF151C2C) 
                : Colors.white.withOpacity(0.01),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isEnabled ? const Color(0xFF1E293B) : Colors.transparent,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            key,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: isEnabled ? textColor : Colors.grey[800],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedNFCBackground() {
    if (_currentStatus != TransactionStatus.waitingForCard && 
        _currentStatus != TransactionStatus.processing) {
      return const SizedBox.shrink();
    }
    
    final color = _isCashierTab ? const Color(0xFF6366F1) : const Color(0xFF10B981);
    
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: List.generate(3, (index) {
            double pulse = _pulseController.value + (index * 0.33);
            if (pulse > 1.0) pulse -= 1.0;
            
            double radius = 100 + (pulse * 250);
            double opacity = (1.0 - pulse) * 0.15;
            
            return Container(
              width: radius,
              height: radius,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withOpacity(opacity),
                  width: 2.0,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
